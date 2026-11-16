/*
 * GammaOS Mouse Mode QS Tile
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tap: toggle mouse mode on/off
 * Long-press: open mouse mode settings in GamepadSettings
 */

package org.lineageos.lineageparts.input;

import android.app.PendingIntent;
import android.content.ComponentName;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemProperties;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

import org.lineageos.lineageparts.R;

public class MouseModeTileService extends TileService {

    private static final String PROP_MOUSE_ACTIVE = "sys.gammaos.gamepad.mouse_active";
    private static final String PROP_GAMEPAD_ENABLE = "persist.gammaos.gamepad.enable";
    private static final String PROP_MOUSE_COMBO1 = "persist.gammaos.gamepad.mouse_combo1";
    private static final String PROP_MOUSE_COMBO2 = "persist.gammaos.gamepad.mouse_combo2";
    private static final String PROP_CONFIG_VERSION = "persist.gammaos.gamepad.config_version";

    @Override
    public void onStartListening() {
        super.onStartListening();
        refresh();
    }

    @Override
    public void onClick() {
        boolean gammapadEnabled = SystemProperties.getInt(PROP_GAMEPAD_ENABLE, 0) != 0;
        if (!gammapadEnabled) {
            SystemProperties.set(PROP_GAMEPAD_ENABLE, "1");
        }

        // Комбинацию не трогаем. Раньше пустую (выключен «Toggle with button
        // combo») плитка заменяла на SELECT+R1 и тем молча включала аккорд,
        // который пользователь выключил или сменил. Режиму мыши аккорд не
        // нужен: gammapad включает его по свойству ниже.

        // Toggle mouse mode via property — daemon polls and reacts
        boolean currentlyActive = SystemProperties.getInt(PROP_MOUSE_ACTIVE, 0) != 0;
        SystemProperties.set(PROP_MOUSE_ACTIVE, currentlyActive ? "0" : "1");

        bumpConfigVersion();
        refresh();
    }

    private void refresh() {
        Tile tile = getQsTile();
        if (tile == null) return;

        boolean gammapadEnabled = SystemProperties.getInt(PROP_GAMEPAD_ENABLE, 0) != 0;
        boolean mouseActive = SystemProperties.getInt(PROP_MOUSE_ACTIVE, 0) != 0;

        if (!gammapadEnabled) {
            tile.setState(Tile.STATE_INACTIVE);
            tile.setSubtitle(null);
        } else if (mouseActive) {
            tile.setState(Tile.STATE_ACTIVE);
            tile.setSubtitle(getString(R.string.gamepad_mouse_mode_on));
        } else {
            tile.setState(Tile.STATE_INACTIVE);
            tile.setSubtitle(null);
        }

        tile.updateTile();
    }

    private void bumpConfigVersion() {
        android.os.SystemProperties.set("persist.gammaos.gamepad.full_reload", "1");
        int version = SystemProperties.getInt(PROP_CONFIG_VERSION, 0);
        SystemProperties.set(PROP_CONFIG_VERSION, String.valueOf(version + 1));
    }
}
