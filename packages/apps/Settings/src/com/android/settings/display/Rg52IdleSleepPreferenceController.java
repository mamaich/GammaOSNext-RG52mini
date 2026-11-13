/*
 * RG52 Mini: Display - Sleep without input.
 *
 * Игры и эмуляторы держат экран включённым, и Screen timeout на них не действует. Этот
 * пункт задаёт время без единого нажатия, после которого консоль засыпает всё равно
 * (Settings.Secure attentive_timeout, механизм PowerManagerService; за 30 секунд до сна
 * показывается предупреждение). Умолчание - config_attentiveTimeout из оверлея
 * device/rg52mini (2 часа).
 */
package com.android.settings.display;

import static android.provider.Settings.Secure.ATTENTIVE_TIMEOUT;

import android.content.Context;
import android.provider.Settings;

import androidx.preference.ListPreference;
import androidx.preference.Preference;
import androidx.preference.PreferenceScreen;

import com.android.settings.R;
import com.android.settings.core.BasePreferenceController;

public class Rg52IdleSleepPreferenceController extends BasePreferenceController
        implements Preference.OnPreferenceChangeListener {

    private static final String NEVER = "-1";

    private ListPreference mListPreference;

    public Rg52IdleSleepPreferenceController(Context context, String key) {
        super(context, key);
    }

    @Override
    public int getAvailabilityStatus() {
        return AVAILABLE;
    }

    @Override
    public void displayPreference(PreferenceScreen screen) {
        super.displayPreference(screen);
        mListPreference = screen.findPreference(getPreferenceKey());
    }

    /** Действующее значение в миллисекундах; всё, что не больше нуля, - «никогда». */
    private long currentTimeout() {
        final int def = mContext.getResources().getInteger(
                com.android.internal.R.integer.config_attentiveTimeout);
        // Пустая строка (её пишет сброс в настройках Android TV) читается как умолчание.
        return Settings.Secure.getInt(mContext.getContentResolver(), ATTENTIVE_TIMEOUT, def);
    }

    @Override
    public void updateState(Preference preference) {
        if (mListPreference == null) return;
        final long timeout = currentTimeout();
        final String value = timeout > 0 ? Long.toString(timeout) : NEVER;
        final int index = mListPreference.findIndexOfValue(value);
        if (index >= 0) {
            mListPreference.setValueIndex(index);
        }
        if (timeout <= 0) {
            mListPreference.setSummary(R.string.rg52_idle_sleep_never);
        } else {
            // Значение не из списка (например, заданное через adb) показываем минутами.
            final CharSequence time = index >= 0 ? mListPreference.getEntries()[index]
                    : (timeout / 60000) + " min";
            mListPreference.setSummary(
                    mContext.getString(R.string.rg52_idle_sleep_summary, time));
        }
    }

    @Override
    public boolean onPreferenceChange(Preference preference, Object newValue) {
        try {
            Settings.Secure.putInt(mContext.getContentResolver(), ATTENTIVE_TIMEOUT,
                    Integer.parseInt((String) newValue));
        } catch (NumberFormatException e) {
            return false;
        }
        updateState(preference);
        return true;
    }
}
