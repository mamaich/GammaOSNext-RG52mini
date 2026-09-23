/*
 * Copyright (C) 2021 The Android Open Source Project
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

package com.android.settings.applications;

import android.app.settings.SettingsEnums;
import android.content.Context;
import android.os.Bundle;
import android.os.SystemProperties;
import android.provider.SearchIndexableResource;

import androidx.preference.Preference;
import androidx.preference.TwoStatePreference;

import com.android.internal.annotations.VisibleForTesting;
import com.android.settings.R;
import com.android.settings.applications.appcompat.UserAspectRatioAppsPreferenceController;
import com.android.settings.dashboard.DashboardFragment;
import com.android.settings.search.BaseSearchIndexProvider;
import com.android.settings.widget.PreferenceCategoryController;
import com.android.settingslib.core.AbstractPreferenceController;
import com.android.settingslib.search.SearchIndexable;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Settings page for apps. */
@SearchIndexable
public class AppDashboardFragment extends DashboardFragment {

    private static final String TAG = "AppDashboardFragment";
    private static final String ADVANCED_CATEGORY_KEY = "advanced_category";
    private static final String ASPECT_RATIO_PREF_KEY = "aspect_ratio_apps";
    private AppsPreferenceController mAppsPreferenceController;

    private static List<AbstractPreferenceController> buildPreferenceControllers(Context context) {
        final List<AbstractPreferenceController> controllers = new ArrayList<>();
        controllers.add(new AppsPreferenceController(context));

        final UserAspectRatioAppsPreferenceController aspectRatioAppsPreferenceController =
                new UserAspectRatioAppsPreferenceController(context, ASPECT_RATIO_PREF_KEY);
        final AdvancedAppsPreferenceCategoryController advancedCategoryController =
                new AdvancedAppsPreferenceCategoryController(context, ADVANCED_CATEGORY_KEY);
        advancedCategoryController.setChildren(List.of(aspectRatioAppsPreferenceController));
        controllers.add(advancedCategoryController);

        return controllers;
    }

    @Override
    public int getMetricsCategory() {
        return SettingsEnums.MANAGE_APPLICATIONS;
    }

    @Override
    protected String getLogTag() {
        return TAG;
    }

    @Override
    public int getHelpResource() {
        return R.string.help_url_apps_and_notifications;
    }

    @Override
    protected int getPreferenceScreenResId() {
        return R.xml.apps;
    }

    @Override
    // RG52 Mini: видимость телефонных приложений в магазинах.
    //
    // Пункт называется «показывать телефонные», а свойство — «только
    // телевизор», и значения у них обратные. Свойство читает SystemConfig
    // через <unavailable-feature-conditional>, а тот оставляет признак
    // android.software.leanback_only ровно когда свойство истинно: имя
    // свойства описывает поведение системы, имя пункта — то, что видит
    // человек. Инверсия живёт здесь, в одном месте.
    //
    // Тот же переключатель есть в TvSettings. Оба приложения настроек на
    // устройстве живые: панель справа — это TvSettings, а из лаунчера
    // открывается вот это.
    private static final String KEY_RG52_PHONE_APPS = "rg52_phone_apps";
    private static final String RG52_TV_ONLY_PROP = "persist.rg52.tv_only";

    @Override
    public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
        super.onCreatePreferences(savedInstanceState, rootKey);

        final Preference phoneApps = findPreference(KEY_RG52_PHONE_APPS);
        if (phoneApps instanceof TwoStatePreference) {
            final TwoStatePreference phoneAppsSwitch = (TwoStatePreference) phoneApps;
            phoneAppsSwitch.setChecked(
                    !SystemProperties.getBoolean(RG52_TV_ONLY_PROP, false));
            phoneAppsSwitch.setOnPreferenceChangeListener((pref, newValue) -> {
                SystemProperties.set(RG52_TV_ONLY_PROP,
                        ((Boolean) newValue) ? "false" : "true");
                return true;
            });
        }
    }

    @Override
    public void onAttach(Context context) {
        super.onAttach(context);
        mAppsPreferenceController = use(AppsPreferenceController.class);
        mAppsPreferenceController.setFragment(this /* fragment */);
        getSettingsLifecycle().addObserver(mAppsPreferenceController);

        final HibernatedAppsPreferenceController hibernatedAppsPreferenceController =
                use(HibernatedAppsPreferenceController.class);
        getSettingsLifecycle().addObserver(hibernatedAppsPreferenceController);
    }

    @VisibleForTesting
    PreferenceCategoryController getAdvancedAppsPreferenceCategoryController() {
        return use(AdvancedAppsPreferenceCategoryController.class);
    }

    @Override
    protected List<AbstractPreferenceController> createPreferenceControllers(Context context) {
        return buildPreferenceControllers(context);
    }

    public static final BaseSearchIndexProvider SEARCH_INDEX_DATA_PROVIDER =
            new BaseSearchIndexProvider() {
                @Override
                public List<SearchIndexableResource> getXmlResourcesToIndex(
                        Context context, boolean enabled) {
                    final SearchIndexableResource sir = new SearchIndexableResource(context);
                    sir.xmlResId = R.xml.apps;
                    return Arrays.asList(sir);
                }

                @Override
                public List<AbstractPreferenceController> createPreferenceControllers(
                        Context context) {
                    return buildPreferenceControllers(context);
                }
            };
}
