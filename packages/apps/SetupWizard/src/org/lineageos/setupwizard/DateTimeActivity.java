/*
 * SPDX-FileCopyrightText: 2016 The CyanogenMod Project
 * SPDX-FileCopyrightText: 2017-2024 The LineageOS Project
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.setupwizard;

import android.app.AlarmManager;
import android.app.AlertDialog;
import android.app.DatePickerDialog;
import android.app.Dialog;
import android.app.TimePickerDialog;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.format.DateFormat;
import android.view.KeyEvent;
import android.view.View;
import android.widget.AdapterView;
import android.widget.Button;
import android.widget.DatePicker;
import android.widget.SimpleAdapter;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.TimePicker;

import androidx.annotation.NonNull;
import androidx.fragment.app.DialogFragment;

import com.android.settingslib.datetime.ZoneGetter;

import org.lineageos.setupwizard.util.SetupWizardUtils;

import java.util.Calendar;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.TimeZone;

public class DateTimeActivity extends BaseSetupWizardActivity implements
        TimePickerDialog.OnTimeSetListener, DatePickerDialog.OnDateSetListener {

    private static final String KEY_ID = "id"; // value: String
    private static final String KEY_DISPLAYNAME = "name"; // value: String
    private static final String KEY_GMT = "gmt"; // value: String
    private static final String KEY_OFFSET = "offset"; // value: int (Integer)

    private TimeZone mCurrentTimeZone;
    private Spinner mTimeZoneSpinner;
    private int mShownTzPosition = -1;
    private TextView mDateTextView;
    private TextView mTimeTextView;

    private final Handler mHandler = new Handler(Looper.getMainLooper());

    private final BroadcastReceiver mIntentReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            updateTimeAndDateDisplay();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setNextText(R.string.next);
        getGlifLayout().setDescriptionText(getString(R.string.date_time_summary));

        final Spinner spinner = findViewById(R.id.timezone_list);
        mTimeZoneSpinner = spinner;
        final SimpleAdapter adapter = constructTimezoneAdapter(this);
        mCurrentTimeZone = TimeZone.getDefault();
        View dateView = findViewById(R.id.date_item);
        dateView.setOnClickListener((view) -> showDatePicker());
        View timeView = findViewById(R.id.time_item);
        timeView.setOnClickListener((view) -> showTimePicker());
        mDateTextView = findViewById(R.id.date_text);
        mTimeTextView = findViewById(R.id.time_text);
        // Pre-select current/default timezone
        mHandler.post(() -> {
            // GammaOS: the spinner reports this initial selection as if the user had picked
            // it, so only a different entry is applied. A fresh install is on GMT, which is
            // not in the list, and used to end up on its first entry, Midway (GMT-11), as
            // soon as this page was shown; now an entry with the same offset is shown.
            mShownTzPosition = getTimeZoneIndex(adapter, mCurrentTimeZone);
            spinner.setAdapter(adapter);
            spinner.setSelection(mShownTzPosition);
            spinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener() {
                @Override
                public void onItemSelected(AdapterView<?> adapterView, View view, int position,
                        long id) {
                    if (position == mShownTzPosition) {
                        return;
                    }
                    mShownTzPosition = position;
                    final Map<?, ?> map = (Map<?, ?>) adapterView.getItemAtPosition(position);
                    final String tzId = (String) map.get(KEY_ID);
                    if (mCurrentTimeZone != null && !mCurrentTimeZone.getID().equals(tzId)) {
                        // Update the system timezone value
                        final AlarmManager alarm =
                                (AlarmManager) getSystemService(Context.ALARM_SERVICE);
                        alarm.setTimeZone(tzId);
                        mCurrentTimeZone = TimeZone.getTimeZone(tzId);
                    }

                }

                @Override
                public void onNothingSelected(AdapterView<?> adapterView) {
                }
            });
            // GammaOS: start on the time zone list rather than on Next, see dispatchKeyEvent().
            spinner.requestFocus();
        });
        // Pre-select current/default date if epoch
        mHandler.post(() -> {
            final Calendar calendar = Calendar.getInstance();
            final boolean isEpoch = calendar.get(Calendar.YEAR) == 1970;
            if (isEpoch) {
                // If epoch, set date to build date
                long timestamp = SetupWizardUtils.getBuildDateTimestamp();
                if (timestamp > 0) {
                    calendar.setTimeInMillis(timestamp * 1000);
                    setDate(DateTimeActivity.this, calendar.get(Calendar.YEAR),
                            calendar.get(Calendar.MONTH), calendar.get(Calendar.DAY_OF_MONTH));
                } else {
                    // no build date available, use a sane default
                    setDate(DateTimeActivity.this, 2017, Calendar.JANUARY, 1);
                }
            }
        });
    }

    @Override
    public void onResume() {
        super.onResume();
        // Register for time ticks and other reasons for time change
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_TIME_TICK);
        filter.addAction(Intent.ACTION_TIME_CHANGED);
        filter.addAction(Intent.ACTION_TIMEZONE_CHANGED);
        registerReceiver(mIntentReceiver, filter, null, null);

        updateTimeAndDateDisplay();
    }

    @Override
    public void onPause() {
        super.onPause();
        unregisterReceiver(mIntentReceiver);
    }

    @Override
    public boolean dispatchKeyEvent(KeyEvent event) {
        // GammaOS: A/Center/Enter always mean Next in the wizard (BaseSetupWizardActivity),
        // so the time zone, date and time here could only be changed with a mouse. On these
        // items A opens them; anywhere else it still goes to the next page.
        if (isSelectKey(event.getKeyCode())) {
            final View focus = getCurrentFocus();
            if (focus != null && (focus == mTimeZoneSpinner
                    || focus.getId() == R.id.date_item || focus.getId() == R.id.time_item)) {
                if (event.getAction() == KeyEvent.ACTION_UP) {
                    focus.performClick();
                }
                return true;
            }
        }
        return super.dispatchKeyEvent(event);
    }

    private static boolean isSelectKey(int keyCode) {
        return keyCode == KeyEvent.KEYCODE_BUTTON_A || keyCode == KeyEvent.KEYCODE_DPAD_CENTER
                || keyCode == KeyEvent.KEYCODE_ENTER;
    }

    // GammaOS: the pickers show number wheels (R.style.DateTimePickerDialog) instead of the
    // clock face and the calendar: up/down change a field, left/right move between fields.
    // A confirms the dialog - on a wheel it would open the on-screen keyboard instead.
    private static void confirmWithA(AlertDialog dialog) {
        dialog.setOnKeyListener((d, keyCode, event) -> {
            if (!isSelectKey(keyCode) || dialog.getCurrentFocus() instanceof Button) {
                return false;
            }
            if (event.getAction() == KeyEvent.ACTION_UP) {
                dialog.getButton(DialogInterface.BUTTON_POSITIVE).performClick();
            }
            return true;
        });
    }

    @Override
    protected int getLayoutResId() {
        return R.layout.setup_datetime_page;
    }

    @Override
    protected int getTitleResId() {
        return R.string.setup_datetime;
    }

    @Override
    protected int getIconResId() {
        return R.drawable.ic_datetime;
    }

    @Override
    public void onDateSet(DatePicker view, int year, int month, int day) {
        setDate(this, year, month, day);
        updateTimeAndDateDisplay();
    }

    @Override
    public void onTimeSet(TimePicker view, int hourOfDay, int minute) {
        setTime(this, hourOfDay, minute);
        updateTimeAndDateDisplay();
    }

    private void showDatePicker() {
        DatePickerFragment datePickerFragment = DatePickerFragment.newInstance();
        datePickerFragment.show(getSupportFragmentManager(), DatePickerFragment.TAG);
    }

    private void showTimePicker() {
        TimePickerFragment timePickerFragment = TimePickerFragment.newInstance();
        timePickerFragment.show(getSupportFragmentManager(), TimePickerFragment.TAG);
    }

    private void updateTimeAndDateDisplay() {
        java.text.DateFormat shortDateFormat = DateFormat.getDateFormat(this);
        final Calendar now = Calendar.getInstance();
        mTimeTextView.setText(DateFormat.getTimeFormat(this).format(now.getTime()));
        mDateTextView.setText(shortDateFormat.format(now.getTime()));
    }

    private static SimpleAdapter constructTimezoneAdapter(Context context) {
        final String[] from = new String[]{KEY_DISPLAYNAME, KEY_GMT};
        final int[] to = new int[]{android.R.id.text1, android.R.id.text2};

        final TimeZoneComparator comparator = new TimeZoneComparator(KEY_OFFSET);
        final List<Map<String, Object>> sortedList = ZoneGetter.getZonesList(context);
        sortedList.sort(comparator);

        return new SimpleAdapter(context,
                sortedList,
                R.layout.date_time_setup_custom_list_item_2,
                from,
                to);
    }

    private static int getTimeZoneIndex(SimpleAdapter adapter, TimeZone tz) {
        final String defaultId = tz.getID();
        final int listSize = adapter.getCount();
        for (int i = 0; i < listSize; i++) {
            final Map<?, ?> map = (Map<?, ?>) adapter.getItem(i);
            final String id = (String) map.get(KEY_ID);
            if (defaultId.equals(id)) {
                // If current timezone is in this list, move focus to it
                return i;
            }
        }
        // GammaOS: not in the list (GMT on a fresh install) - an entry with the same
        // current offset shows the same time. One with the same standard offset is
        // preferred: for GMT that is UTC rather than the Azores on summer time.
        final Integer offset = tz.getOffset(System.currentTimeMillis());
        int sameOffset = -1;
        for (int i = 0; i < listSize; i++) {
            final Map<?, ?> map = (Map<?, ?>) adapter.getItem(i);
            if (!offset.equals(map.get(KEY_OFFSET))) {
                continue;
            }
            final String id = (String) map.get(KEY_ID);
            if (TimeZone.getTimeZone(id).getRawOffset() == tz.getRawOffset()) {
                return i;
            }
            if (sameOffset < 0) {
                sameOffset = i;
            }
        }
        return Math.max(sameOffset, 0);
    }

    private static void setDate(Context context, int year, int month, int day) {
        Calendar c = Calendar.getInstance();

        c.set(Calendar.YEAR, year);
        c.set(Calendar.MONTH, month);
        c.set(Calendar.DAY_OF_MONTH, day);
        long when = c.getTimeInMillis();

        if (when / 1000 < Integer.MAX_VALUE) {
            ((AlarmManager) context.getSystemService(Context.ALARM_SERVICE)).setTime(when);
        }
    }

    private static void setTime(Context context, int hourOfDay, int minute) {
        Calendar c = Calendar.getInstance();

        c.set(Calendar.HOUR_OF_DAY, hourOfDay);
        c.set(Calendar.MINUTE, minute);
        c.set(Calendar.SECOND, 0);
        c.set(Calendar.MILLISECOND, 0);
        long when = c.getTimeInMillis();

        if (when / 1000 < Integer.MAX_VALUE) {
            ((AlarmManager) context.getSystemService(Context.ALARM_SERVICE)).setTime(when);
        }
    }

    private static class TimeZoneComparator implements Comparator<Map<?, ?>> {
        private final String mSortingKey;

        public TimeZoneComparator(String sortingKey) {
            mSortingKey = sortingKey;
        }

        public int compare(Map<?, ?> map1, Map<?, ?> map2) {
            Object value1 = map1.get(mSortingKey);
            Object value2 = map2.get(mSortingKey);

            /*
             * This should never happen, but just in-case, put non-comparable
             * items at the end.
             */
            if (!isComparable(value1)) {
                return isComparable(value2) ? 1 : 0;
            } else if (!isComparable(value2)) {
                return -1;
            }

            return ((Comparable) value1).compareTo(value2);
        }

        private boolean isComparable(Object value) {
            return (value instanceof Comparable);
        }
    }

    public static class TimePickerFragment extends DialogFragment
            implements TimePickerDialog.OnTimeSetListener {

        private static final String TAG = TimePickerFragment.class.getSimpleName();

        public static TimePickerFragment newInstance() {
            return new TimePickerFragment();
        }

        @Override
        public void onTimeSet(TimePicker view, int hourOfDay, int minute) {
            ((DateTimeActivity) getActivity()).onTimeSet(view, hourOfDay, minute);
        }

        @NonNull
        @Override
        public Dialog onCreateDialog(Bundle savedInstanceState) {
            final Calendar calendar = Calendar.getInstance();
            final TimePickerDialog dialog = new TimePickerDialog(
                    getActivity(),
                    R.style.DateTimePickerDialog,
                    this,
                    calendar.get(Calendar.HOUR_OF_DAY),
                    calendar.get(Calendar.MINUTE),
                    DateFormat.is24HourFormat(getActivity()));
            confirmWithA(dialog);
            return dialog;
        }
    }

    public static class DatePickerFragment extends DialogFragment
            implements DatePickerDialog.OnDateSetListener {

        private static final String TAG = DatePickerFragment.class.getSimpleName();

        public static DatePickerFragment newInstance() {
            return new DatePickerFragment();
        }

        @Override
        public void onDateSet(DatePicker view, int year, int month, int day) {
            ((DateTimeActivity) getActivity()).onDateSet(view, year, month, day);
        }

        @NonNull
        @Override
        public Dialog onCreateDialog(Bundle savedInstanceState) {
            final Calendar calendar = Calendar.getInstance();
            final DatePickerDialog dialog = new DatePickerDialog(
                    getActivity(),
                    R.style.DateTimePickerDialog,
                    this,
                    calendar.get(Calendar.YEAR),
                    calendar.get(Calendar.MONTH),
                    calendar.get(Calendar.DAY_OF_MONTH));
            confirmWithA(dialog);
            return dialog;
        }
    }
}
