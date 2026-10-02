/*
 * Copyright (C) 2026 GammaOS
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

// RG52: копия packages/apps/Settings/src/com/android/settings/handheld/HdmiModes.java
// для GammaOS Toolbox в настройках Android TV (их открывает оболочка nano).
// Правится в обоих местах одинаково, отличается только пакет.
package com.android.tv.settings.gammaos;

import android.os.SystemProperties;
import android.text.TextUtils;
import android.util.Log;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * RG52: HDMI output mode for the Rockchip hardware composer.
 *
 * The vendor HWC picks the external display mode from
 * persist.vendor.resolution.aux and re-reads it whenever
 * vendor.display.timeline changes. Two value forms work:
 * "WxH@Hz" selects a mode the kernel already offers (refresh must match),
 * and the full timing form "WxH@Hz-hss-hse-htot-vss-vse-vtot-flags-clk"
 * makes the HWC build that mode itself, so it works even when the TV's
 * EDID does not list it. An empty value means "HWC picks the best mode".
 *
 * The kernel exposes only mode names (no refresh rates) in sysfs, so the
 * list is built from the EDID blob next to it; the names file is used to
 * drop sizes the kernel rejected (the rk628 bridge tops out at 148.5 MHz
 * and 1920x1080).
 */
final class HdmiModes {
    private static final String TAG = "GammaOSHdmiModes";

    static final String PROP_MODE = "persist.vendor.resolution.aux";
    private static final String PROP_TIMELINE = "vendor.display.timeline";
    private static final String DRM_DIR = "/sys/class/drm";

    /** One selectable mode: what the list shows and what goes into the property. */
    static final class Mode {
        final int width, height, hz;
        final String value;

        Mode(int width, int height, int hz, String value) {
            this.width = width;
            this.height = height;
            this.hz = hz;
            this.value = value;
        }

        String label() {
            return width + "×" + height + ", " + hz + " Hz";
        }
    }

    /**
     * Modes always offered, with full CEA/DMT timings so the HWC can build them
     * without EDID: 640x480, 1024x768, 1280x720 and 1920x1080 at 60 Hz.
     */
    private static final Mode[] FORCED = {
        new Mode(640, 480, 60, "640x480@60.00-656-752-800-490-492-525-a-25175"),
        new Mode(1024, 768, 60, "1024x768@60.00-1048-1184-1344-771-777-806-a-65000"),
        new Mode(1280, 720, 60, "1280x720@60.00-1390-1430-1650-725-730-750-5-74250"),
        new Mode(1920, 1080, 60, "1920x1080@60.00-2008-2052-2200-1084-1089-1125-5-148500"),
    };

    private static final int MAX_CLOCK_KHZ = 148500;

    /** EDID established timings, bytes 35..37, MSB first; interlaced 1024x768@87 left out. */
    private static final int[][] ESTABLISHED = {
        {720, 400, 70}, {720, 400, 88}, {640, 480, 60}, {640, 480, 67},
        {640, 480, 72}, {640, 480, 75}, {800, 600, 56}, {800, 600, 60},
        {800, 600, 72}, {800, 600, 75}, {832, 624, 75}, null,
        {1024, 768, 60}, {1024, 768, 70}, {1024, 768, 75}, {1280, 1024, 75},
        {1152, 870, 75},
    };

    /** CEA-861 progressive VICs up to 148.5 MHz: {vic, width, height, hz}. */
    private static final int[][] VICS = {
        {1, 640, 480, 60}, {2, 720, 480, 60}, {3, 720, 480, 60}, {4, 1280, 720, 60},
        {14, 1440, 480, 60}, {15, 1440, 480, 60}, {16, 1920, 1080, 60},
        {17, 720, 576, 50}, {18, 720, 576, 50}, {19, 1280, 720, 50},
        {29, 1440, 576, 50}, {30, 1440, 576, 50}, {31, 1920, 1080, 50},
        {32, 1920, 1080, 24}, {33, 1920, 1080, 25}, {34, 1920, 1080, 30},
        {41, 1280, 720, 100}, {42, 720, 576, 100}, {43, 720, 576, 100},
        {47, 1280, 720, 120}, {48, 720, 480, 120}, {49, 720, 480, 120},
        {60, 1280, 720, 24}, {61, 1280, 720, 25}, {62, 1280, 720, 30},
    };

    private HdmiModes() {}

    /** The HDMI connector's sysfs directory, or null when there is none. */
    private static File connectorDir() {
        File[] dirs = new File(DRM_DIR).listFiles();
        if (dirs == null) return null;
        for (File d : dirs) {
            if (d.getName().matches("card\\d+-HDMI-A-\\d+")) return d;
        }
        return null;
    }

    private static byte[] readAll(File f) {
        try (InputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[4096];
            int n = 0, r;
            while (n < buf.length && (r = in.read(buf, n, buf.length - n)) > 0) n += r;
            byte[] out = new byte[n];
            System.arraycopy(buf, 0, out, 0, n);
            return out;
        } catch (IOException e) {
            return new byte[0];
        }
    }

    /**
     * All modes to offer: the EDID ones the kernel kept plus the forced ones,
     * sorted by height, then width, then refresh (highest first), no duplicates.
     */
    static List<Mode> list() {
        Map<String, Mode> modes = new LinkedHashMap<>();
        for (Mode m : FORCED) modes.put(m.width + "x" + m.height + "@" + m.hz, m);

        File dir = connectorDir();
        if (dir != null) {
            Set<String> kernelSizes = new HashSet<>();
            String names = new String(readAll(new File(dir, "modes")), StandardCharsets.US_ASCII);
            for (String line : names.split("\n")) {
                if (!line.trim().isEmpty()) kernelSizes.add(line.trim());
            }
            List<int[]> edid = parseEdid(readAll(new File(dir, "edid")));
            for (int[] m : edid) {
                String size = m[0] + "x" + m[1];
                String key = size + "@" + m[2];
                if (!kernelSizes.contains(size) || modes.containsKey(key)) continue;
                modes.put(key, new Mode(m[0], m[1], m[2], key));
            }
        }

        List<Mode> out = new ArrayList<>(modes.values());
        Collections.sort(out, (a, b) -> a.height != b.height ? a.height - b.height
                : a.width != b.width ? a.width - b.width : b.hz - a.hz);
        return out;
    }

    /** Parse EDID into {width, height, hz} progressive modes; empty on a bad blob. */
    static List<int[]> parseEdid(byte[] e) {
        List<int[]> out = new ArrayList<>();
        if (e.length < 128 || (e[0] & 0xff) != 0 || (e[1] & 0xff) != 0xff) return out;

        for (int i = 0; i < ESTABLISHED.length; i++) {
            int b = e[35 + i / 8] & 0xff;
            if ((b & (0x80 >> (i % 8))) != 0 && ESTABLISHED[i] != null) out.add(ESTABLISHED[i]);
        }

        for (int i = 38; i < 54; i += 2) {
            int b0 = e[i] & 0xff, b1 = e[i + 1] & 0xff;
            if (b0 <= 1) continue;   // unused (0x01 0x01) or reserved
            int w = (b0 + 31) * 8, h;
            switch (b1 >> 6) {
                case 0: h = w * 10 / 16; break;
                case 1: h = w * 3 / 4; break;
                case 2: h = w * 4 / 5; break;
                default: h = w * 9 / 16; break;
            }
            out.add(new int[] {w, h, (b1 & 0x3f) + 60});
        }

        for (int off = 54; off < 126; off += 18) addDtd(e, off, out);

        int blocks = e[126] & 0xff;
        for (int n = 1; n <= blocks && (n + 1) * 128 <= e.length; n++) {
            int base = n * 128;
            if ((e[base] & 0xff) != 0x02) continue;   // CEA-861 extension only
            int dtdStart = e[base + 2] & 0xff;
            int p = base + 4;
            while (dtdStart >= 4 && p < base + dtdStart) {
                int tag = (e[p] & 0xff) >> 5, len = e[p] & 0x1f;
                if (tag == 2) {   // video data block: short video descriptors
                    for (int k = 1; k <= len && p + k < base + 128; k++) {
                        int svd = e[p + k] & 0xff;
                        int vic = (svd >= 129 && svd <= 192) ? svd & 0x7f : svd;
                        for (int[] v : VICS) {
                            if (v[0] == vic) out.add(new int[] {v[1], v[2], v[3]});
                        }
                    }
                }
                p += len + 1;
            }
            if (dtdStart >= 4) {
                for (int off = base + dtdStart; off + 18 <= base + 127; off += 18) addDtd(e, off, out);
            }
        }
        return out;
    }

    /** Detailed timing descriptor at off, if it is one, progressive and not too fast. */
    private static void addDtd(byte[] e, int off, List<int[]> out) {
        int clk = ((e[off] & 0xff) | (e[off + 1] & 0xff) << 8) * 10;   // kHz
        if (clk == 0 || clk > MAX_CLOCK_KHZ) return;
        if ((e[off + 17] & 0x80) != 0) return;   // interlaced
        int hact = (e[off + 2] & 0xff) | (e[off + 4] & 0xf0) << 4;
        int hblank = (e[off + 3] & 0xff) | (e[off + 4] & 0x0f) << 8;
        int vact = (e[off + 5] & 0xff) | (e[off + 7] & 0xf0) << 4;
        int vblank = (e[off + 6] & 0xff) | (e[off + 7] & 0x0f) << 8;
        long total = (long) (hact + hblank) * (vact + vblank);
        if (hact == 0 || vact == 0 || total == 0) return;
        int hz = (int) Math.round(clk * 1000.0 / total);
        out.add(new int[] {hact, vact, hz});
    }

    static String current() {
        return SystemProperties.get(PROP_MODE, "");
    }

    /** Store the mode and make the HWC apply it now (no replug needed). */
    static void apply(String value) {
        SystemProperties.set(PROP_MODE, value == null ? "" : value);
        int timeline = SystemProperties.getInt(PROP_TIMELINE, 0);
        SystemProperties.set(PROP_TIMELINE, Integer.toString(timeline + 1));
        Log.i(TAG, "HDMI mode set to \"" + (TextUtils.isEmpty(value) ? "auto" : value) + "\"");
    }
}
