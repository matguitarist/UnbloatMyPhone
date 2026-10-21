package app.unbloatmyphone;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * Run by UnbloatMyPhone over ADB, never installed:
 *   CLASSPATH=/data/local/tmp/ump-helper.dex app_process / app.unbloatmyphone.AppIcons SIZE PKG...
 * Prints one line per package: "package TAB label TAB base64 PNG" (empty fields when not found).
 * Android itself loads the name in the phone's language and draws the icon, as the home screen would.
 */
public final class AppIcons {
    public static void main(String[] args) throws Exception {
        int size = Integer.parseInt(args[0]);
        PackageManager pm = systemContext().getPackageManager();
        PrintStream out = new PrintStream(System.out, false, "UTF-8");
        for (int i = 1; i < args.length; i++) {
            String pkg = args[i], label = "", png = "";
            try {
                ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
                label = pm.getApplicationLabel(ai).toString().replaceAll("[\\t\\r\\n]+", " ").trim();
                png = render(pm.getApplicationIcon(ai), size);
            } catch (Throwable ignored) {
                // Not installed for this user, or an icon Android can't draw here: keep what we have.
            }
            out.print(pkg + "\t" + label + "\t" + png + "\n");
        }
        out.flush();
    }

    private static String render(Drawable d, int size) {
        Bitmap b = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        d.setBounds(0, 0, size, size);
        d.draw(new Canvas(b));
        ByteArrayOutputStream png = new ByteArrayOutputStream();
        b.compress(Bitmap.CompressFormat.PNG, 100, png);
        return Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP);
    }

    /** The system context, the way screen-mirroring tools get one outside an app. */
    private static Context systemContext() throws Exception {
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        Class<?> c = Class.forName("android.app.ActivityThread");
        Constructor<?> ctor = c.getDeclaredConstructor();
        ctor.setAccessible(true);
        Object thread = ctor.newInstance();
        Field current = c.getDeclaredField("sCurrentActivityThread");
        current.setAccessible(true);
        current.set(null, thread);
        Method get = c.getDeclaredMethod("getSystemContext");
        return (Context) get.invoke(thread);
    }
}
