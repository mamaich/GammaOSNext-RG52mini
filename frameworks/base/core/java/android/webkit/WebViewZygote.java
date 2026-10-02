/*
 * Copyright (C) 2016 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package android.webkit;

import static android.webkit.Flags.updateServiceV2;

import android.content.pm.PackageInfo;
import android.os.Build;
import android.os.ChildZygoteProcess;
import android.os.Process;
import android.os.SystemProperties;
import android.os.ZygoteProcess;
import android.text.TextUtils;
import android.util.Log;

import com.android.internal.annotations.GuardedBy;
import com.android.internal.os.Zygote;

import dalvik.system.VMRuntime;

/** @hide */
public class WebViewZygote {
    private static final String LOGTAG = "WebViewZygote";

    /**
     * Lock object that protects all other static members.
     */
    private static final Object sLock = new Object();

    /**
     * Instance that maintains the socket connection to the zygote. This is {@code null} if the
     * zygote is not running or is not connected.
     */
    @GuardedBy("sLock")
    private static ChildZygoteProcess sZygote;

    /**
     * Information about the selected WebView package. This is set from #onWebViewProviderChanged().
     * GammaOS: written under sLock, but volatile and read without it - see getPackageName().
     */
    private static volatile PackageInfo sPackage;

    /**
     * Flag for whether multi-process WebView is enabled. If this is {@code false}, the zygote will
     * not be started. Should be removed entirely after we remove the updateServiceV2 flag.
     */
    @GuardedBy("sLock")
    private static boolean sMultiprocessEnabled = false;

    /**
     * GammaOS lazy 32-bit zygote: true while the child zygote runs with a 32-bit ABI, i.e. was
     * forked from zygote_secondary. Written under sLock, read without it so ActivityManagerService
     * can check it under its own lock.
     */
    private static volatile boolean sRunning32Bit = false;

    /**
     * GammaOS lazy 32-bit zygote: whether the WebView child zygote is alive as a child of
     * zygote_secondary. While it is, zygote_secondary must not be reaped: the child would be
     * orphaned with descriptors from a detached mount namespace and abort on its next fork.
     */
    public static boolean isRunning32Bit() {
        return sRunning32Bit;
    }

    /**
     * GammaOS lazy 32-bit zygote (persist.gammaos.lazy32 with ro.zygote.disable_secondary=1):
     * zygote_secondary is started by the first 32-bit fork and reaped after the last 32-bit app
     * exits, so nothing 32-bit should be started ahead of time - neither the 32-bit RELRO nor
     * the WebView zygote (32-bit here: the WebView package is armeabi-v7a primary).
     */
    public static boolean isLazy32BitZygote() {
        return SystemProperties.getBoolean("persist.gammaos.lazy32", false)
                && SystemProperties.getBoolean("ro.zygote.disable_secondary", false);
    }

    public static ZygoteProcess getProcess() {
        synchronized (sLock) {
            if (sZygote != null) return sZygote;

            connectToZygoteIfNeededLocked();
            return sZygote;
        }
    }

    public static String getPackageName() {
        // GammaOS lazy 32-bit zygote: no sLock here. getProcess() holds sLock for the whole cold
        // start of the WebView zygote (zygote_secondary start and preload, the child fork and its
        // preload - seconds), while ActiveServices calls this and isMultiprocessEnabled() under
        // the global AMS lock for every renderer bind: waiting on sLock there would stall the
        // whole system for that time. sPackage is volatile and only ever replaced as a whole.
        return sPackage.packageName;
    }

    public static boolean isMultiprocessEnabled() {
        if (updateServiceV2()) {
            return sPackage != null;    // lock-free, see getPackageName()
        }
        synchronized (sLock) {
            return sMultiprocessEnabled && sPackage != null;
        }
    }

    public static void setMultiprocessEnabled(boolean enabled) {
        if (updateServiceV2()) {
            throw new IllegalStateException(
                    "setMultiprocessEnabled shouldn't be called if update_service_v2 flag is set.");
        }
        synchronized (sLock) {
            sMultiprocessEnabled = enabled;

            // When multi-process is disabled, kill the zygote. When it is enabled,
            // the zygote will be started when it is first needed in getProcess().
            if (!enabled) {
                stopZygoteLocked();
            }
        }
    }

    static void onWebViewProviderChanged(PackageInfo packageInfo) {
        synchronized (sLock) {
            sPackage = packageInfo;

            // If multi-process is not enabled, then do not start the zygote service.
            if (!sMultiprocessEnabled) {
                return;
            }

            stopZygoteLocked();
        }
    }

    @GuardedBy("sLock")
    private static void stopZygoteLocked() {
        if (sZygote != null) {
            // Close the connection and kill the zygote process. This will not cause
            // child processes to be killed by itself. But if this is called in response to
            // setMultiprocessEnabled() or onWebViewProviderChanged(), the WebViewUpdater
            // will kill all processes that depend on the WebView package.
            sZygote.close();
            Process.killProcess(sZygote.getPid());
            sZygote = null;
            sRunning32Bit = false;
        }
    }

    @GuardedBy("sLock")
    private static void connectToZygoteIfNeededLocked() {
        if (sZygote != null) {
            return;
        }

        if (sPackage == null) {
            Log.e(LOGTAG, "Cannot connect to zygote, no package specified");
            return;
        }

        try {
            String abi = sPackage.applicationInfo.primaryCpuAbi;
            // GammaOS Nano: on ATV builds with ZYGOTE_FORCE_64=true, only
            // zygote64 runs - there is no zygote_secondary to service 32-bit
            // ABI requests. The WebView APK is detected by PackageManager
            // with primaryCpuAbi=armeabi-v7a (PM prefers the first matching
            // ABI which is armv7) and secondaryCpuAbi=arm64-v8a. If we ask
            // the child-zygote for armeabi-v7a, openZygoteSocketIfNeeded
            // tries primary zygote64 (doesn't match), falls back to
            // mZygoteSecondarySocketAddress, which has no socket file, and
            // every Chromium sandbox subprocess (the WebView renderer used
            // by SmartTube playback, etc) crashes with "Starting child-zygote
            // through Zygote failed: No such file or directory". Force the
            // ABI to the 64-bit secondary when the device is 64-bit-only.
            if (abi != null && Build.SUPPORTED_32_BIT_ABIS.length == 0
                    && sPackage.applicationInfo.secondaryCpuAbi != null) {
                Log.i(LOGTAG, "GammaOS Nano: ZYGOTE_FORCE_64 device, switching "
                        + "WebView child-zygote ABI from " + abi + " to "
                        + sPackage.applicationInfo.secondaryCpuAbi);
                abi = sPackage.applicationInfo.secondaryCpuAbi;
            }
            // GammaOS lazy 32-bit zygote: zygote_secondary started on demand is never preloaded
            // (it runs with --enable-lazy-preload, and SystemServer no longer sends it
            // --preload-default at boot). Preload it before forking the WebView zygote from it,
            // as before: the child inherits the preloaded classes and resources and the address
            // space reserved for the WebView RELRO. A no-op if it is already preloaded; a
            // failure is not fatal - the WebView zygote then loads everything itself.
            if (abi != null && !VMRuntime.is64BitAbi(abi) && isLazy32BitZygote()) {
                try {
                    Process.ZYGOTE_PROCESS.preloadDefault(abi);
                } catch (Exception e) {
                    Log.w(LOGTAG, "Could not preload zygote_secondary for the WebView zygote", e);
                }
            }
            int runtimeFlags = Zygote.getMemorySafetyRuntimeFlagsForSecondaryZygote(
                    sPackage.applicationInfo, null);
            sZygote = Process.ZYGOTE_PROCESS.startChildZygote(
                    "com.android.internal.os.WebViewZygoteInit",
                    "webview_zygote",
                    Process.WEBVIEW_ZYGOTE_UID,
                    Process.WEBVIEW_ZYGOTE_UID,
                    null,  // gids
                    runtimeFlags,
                    "webview_zygote",  // seInfo
                    abi,  // abi
                    TextUtils.join(",", Build.SUPPORTED_ABIS),
                    null, // instructionSet
                    Process.FIRST_ISOLATED_UID,
                    Integer.MAX_VALUE); // TODO(b/123615476) deal with user-id ranges properly
            sRunning32Bit = abi != null && !VMRuntime.is64BitAbi(abi);
            ZygoteProcess.waitForConnectionToZygote(sZygote.getPrimarySocketAddress());
            sZygote.preloadApp(sPackage.applicationInfo, abi);
        } catch (Exception e) {
            Log.e(LOGTAG, "Error connecting to webview zygote", e);
            stopZygoteLocked();
        }
    }
}
