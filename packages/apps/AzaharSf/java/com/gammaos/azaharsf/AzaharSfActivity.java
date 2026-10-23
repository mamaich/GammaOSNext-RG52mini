/*
 * AzaharSfActivity: starts azahar-nano, the Nintendo 3DS emulator of the GammaOS Nano
 * shell, from normal Android (RG52 Mini).
 *
 * In the nano shell, nano writes the ROM path to /data/system/nano_azahar_nano_rom.txt and
 * sets sys.gammaos.azahar_nano.start; init stops the shell and runs the emulator, which brings
 * the shell back when it exits. In normal Android the launcher (Daijishō) must stay, so this
 * activity does the nano part itself and sets sys.gammaos.azahar_nano.start_app instead
 * (azahar-nano.rc): the emulator uses its SurfaceFlinger backend, whose layer sits above every
 * window, and nothing is restarted when the session ends.
 *
 * While the game runs we hold the foreground. azahar-nano reads the pad from evdev itself, so
 * the keys Android delivers as well must not reach the launcher under us; HOME is kept from the
 * framework for such a session in PhoneWindowManager. When the session ends we finish, and the
 * launcher is back. If the system takes the activity away, onDestroy asks the emulator to quit;
 * if it kills our process outright, the emulator notices through sys.gammaos.azahar_nano.host_pid
 * and quits by itself.
 */
package com.gammaos.azaharsf;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemProperties;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.widget.TextView;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

public class AzaharSfActivity extends Activity {
    private static final String TAG = "AzaharSf";
    // The file azahar-nano reads the ROM path from (main.cpp, kRomPathFile).
    private static final String ROM_FILE = "/data/system/nano_azahar_nano_rom.txt";
    private static final String P_SESSION = "sys.gammaos.azahar_nano.session";
    private static final String P_HOST = "sys.gammaos.azahar_nano.host";
    private static final String P_HOST_PID = "sys.gammaos.azahar_nano.host_pid";
    // Seconds to wait for the session to come up before giving up.
    private static final int START_TIMEOUT_S = 20;

    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private final Runnable mPoll = this::poll;
    // Back belongs to azahar-nano (short press - its menu, long press - save and quit); if the
    // framework finished us on Back, the game would go on with nothing holding the foreground.
    private final OnBackInvokedCallback mNoOpBack = () -> { };
    private TextView mText;
    private boolean mStarted;
    private boolean mSawRunning;
    private boolean mFinishing;
    private int mWaited;
    private int mGoneTicks;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        // Shown until the emulator's layer covers it, and for an error.
        mText = new TextView(this);
        mText.setText("Loading...");
        mText.setTextColor(Color.WHITE);
        mText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        mText.setGravity(Gravity.CENTER);
        mText.setBackgroundColor(Color.BLACK);
        setContentView(mText);
        hideSystemUi();

        getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                OnBackInvokedDispatcher.PRIORITY_DEFAULT, mNoOpBack);

        String rom = romPath(getIntent());
        if (rom == null) {
            fail("Start 3DS games from Daijisho (Nintendo 3DS) or the GammaOS Nano shell");
            return;
        }
        if (!writeRomPath(rom)) {
            fail("Cannot pass the ROM to azahar-nano");
            return;
        }
        Log.i(TAG, "ROM " + rom);
    }

    // Daijishō passes {file.path} as the ROM extra; a plain file:// VIEW works as well.
    private static String romPath(Intent intent) {
        String rom = intent.getStringExtra("ROM");
        if (rom == null || rom.isEmpty()) {
            Uri data = intent.getData();
            if (data != null && "file".equals(data.getScheme())) rom = data.getPath();
        }
        return rom == null || rom.isEmpty() ? null : rom;
    }

    private static boolean writeRomPath(String rom) {
        File tmp = new File(ROM_FILE + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write((rom + "\n").getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            Log.e(TAG, "writing " + tmp + ": " + e);
            return false;
        }
        tmp.setReadable(true, false);
        if (!tmp.renameTo(new File(ROM_FILE))) {
            Log.e(TAG, "renaming " + tmp + " to " + ROM_FILE + " failed");
            return false;
        }
        return true;
    }

    private void hideSystemUi() {
        getWindow().getDecorView().setSystemUiVisibility(
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_FULLSCREEN
                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        // singleTask: a second launch while a game runs only brings us back to the front.
        super.onNewIntent(intent);
        Log.i(TAG, "already hosting a session, new launch ignored");
    }

    @Override
    protected void onResume() {
        super.onResume();
        hideSystemUi();
        if (!mStarted && !mFinishing) {
            mStarted = true;
            // azahar-nano watches this process and quits if it is killed (no onDestroy then).
            SystemProperties.set(P_HOST_PID, String.valueOf(Process.myPid()));
            SystemProperties.set("sys.gammaos.azahar_nano.start_app", "1");
        }
        if (!mFinishing) {
            mHandler.removeCallbacks(mPoll);
            mHandler.postDelayed(mPoll, 1000);
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        mHandler.removeCallbacks(mPoll);
    }

    private boolean sessionRunning() {
        return "1".equals(SystemProperties.get(P_SESSION, "0"))
                && "app".equals(SystemProperties.get(P_HOST, ""));
    }

    // Finish once our session has come up and ended (azahar-nano clears the session flag
    // through init's session_done when it exits).
    private void poll() {
        if (sessionRunning()) {
            mSawRunning = true;
            mGoneTicks = 0;
        } else if (mSawRunning) {
            if (++mGoneTicks >= 2) {
                mFinishing = true;
                finish();
                return;
            }
        } else if (++mWaited >= START_TIMEOUT_S) {
            fail("azahar-nano did not start");
            return;
        }
        mHandler.postDelayed(mPoll, 1000);
    }

    private void fail(String message) {
        Log.w(TAG, message);
        mFinishing = true;
        mText.setText(message);
        mHandler.postDelayed(this::finish, 3000);
    }

    @Override
    protected void onDestroy() {
        mHandler.removeCallbacksAndMessages(null);
        // Taken away mid-game (the system closed us): let the emulator save and quit rather
        // than leave its layer over the launcher.
        if (mStarted && !mFinishing && sessionRunning()) {
            Log.w(TAG, "destroyed during the session, asking azahar-nano to quit");
            SystemProperties.set("sys.gammaos.azahar_nano.quit", "1");
        }
        super.onDestroy();
    }

    // The pad belongs to azahar-nano while we are up; only volume stays with Android.
    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        switch (event.getKeyCode()) {
            case KeyEvent.KEYCODE_VOLUME_UP:
            case KeyEvent.KEYCODE_VOLUME_DOWN:
            case KeyEvent.KEYCODE_VOLUME_MUTE:
                return super.dispatchKeyEvent(event);
            default:
                return true;
        }
    }

    @Override
    public boolean dispatchGenericMotionEvent(MotionEvent event) {
        return true;
    }

    @Override
    public void onBackPressed() {
        // Swallowed, see mNoOpBack.
    }
}
