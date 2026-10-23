
package com.twoshipfork.mm;
import org.libsdl.app.SDLActivity;

import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.provider.Settings;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.FileOutputStream;
import java.io.FileInputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.zip.ZipFile;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import android.Manifest;
import android.content.pm.PackageManager;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import android.os.Build;
import android.widget.Toast;

import android.util.Log;

import android.view.ViewGroup;
import android.view.Gravity;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.view.LayoutInflater;
import android.view.MotionEvent;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.widget.ImageView;

//This class is the main SDLActivity and just sets up a bunch of default files and the input overlay
public class MainActivity extends SDLActivity{

    SharedPreferences preferences;
    private static final CountDownLatch setupLatch = new CountDownLatch(1);
    private static String currentDataRootPath = "/storage/emulated/0/2S2H";
    private static final String PREF_DATA_ROOT_PATH = "dataRootPath";
    private static final String PREF_LEGACY_DATA_MIGRATION_COMPLETE = "legacyDataMigrationComplete";
    private static final String PREF_TOUCH_CONTROLS_DISABLED = "touchControlsDisabled";
    // Legacy key name: true means the touch controls are hidden, not visible.
    private static final String PREF_TOUCH_CONTROLS_HIDDEN = "controlsVisible";
    private static final String PREF_TOUCH_FACE_BUTTON_LAYOUT = "touchFaceButtonLayout";
    private static final String PREF_TOUCH_LEFT_STICK_FLOATING = "touchLeftStickFloating";
    private static final int TOUCH_FACE_BUTTON_LAYOUT_ABXY = 0;
    private static final int TOUCH_FACE_BUTTON_LAYOUT_BAYX = 1;
    private static final int TOUCH_FACE_BUTTON_LAYOUT_GAMECUBE = 2;
    private static final String SUPPORT_FILES_VERSION_MARKER = ".android_support_files_version";
    private static final String SAFE_MODE_MARKER = ".android_safe_mode";
    private static final String SUPPORT_ARCHIVE = "2ship.o2r";
    private static final String DEFAULT_SHADER = "shaders/opengl/default.shader.glsl";
    private AlertDialog dataRootMigrationDialog;
    private AlertDialog setupProgressDialog;
    private boolean supportFilesNeedRefresh;
    private boolean recoverWithoutMods;

    @Override
    protected void onCreate(Bundle savedInstanceState) {

        preferences = getSharedPreferences("com.twoshipfork.mm.prefs",Context.MODE_PRIVATE);

        updateCurrentDataRootPath();
        recoverWithoutMods = AndroidCrashReporter.install(this, getTargetRootFolder());

        if (hasStoragePermission()) {
            beginSetupOrChooseDataRoot();
        } else {
            requestStoragePermission();
        }

        super.onCreate(savedInstanceState);

        boolean debuggable = (getApplicationInfo().flags & android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0;
        if (debuggable && getIntent().getBooleanExtra("test_native_crash_report", false)) {
            nativeTestCrashReporter();
        }
        if (debuggable && getIntent().getBooleanExtra("test_java_crash_report", false)) {
            throw new IllegalStateException("Crash reporter verification");
        }

        setupControllerOverlay();
        applyImmersiveFullscreen();
        attachController();
    }

    @Override
    public void loadLibraries() {
        super.loadLibraries();
        nativeInstallCrashReporter(AndroidCrashReporter.getNativeReportFile().getAbsolutePath(),
                BuildConfig.VERSION_NAME);
    }

    private native void nativeInstallCrashReporter(String reportPath, String versionName);
    private native void nativeTestCrashReporter();

    @Override
    protected void onResume() {
        super.onResume();
        applyImmersiveFullscreen();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) {
            applyImmersiveFullscreen();
        }
    }

    private void applyImmersiveFullscreen() {
        Window window = getWindow();
        if (window == null) {
            return;
        }

        View decorView = window.getDecorView();
        int flags = View.SYSTEM_UI_FLAG_FULLSCREEN |
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION |
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY |
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN |
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION |
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE;
        decorView.setSystemUiVisibility(flags);
        window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
        window.clearFlags(WindowManager.LayoutParams.FLAG_FORCE_NOT_FULLSCREEN);

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            window.setStatusBarColor(Color.TRANSPARENT);
            window.setNavigationBarColor(Color.TRANSPARENT);
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            WindowManager.LayoutParams attributes = window.getAttributes();
            attributes.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
            window.setAttributes(attributes);
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.setNavigationBarContrastEnforced(false);
            window.setStatusBarContrastEnforced(false);
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false);
            WindowInsetsController controller = window.getInsetsController();
            if (controller != null) {
                controller.hide(WindowInsets.Type.systemBars());
                controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        }
    }

    public static void waitForSetupFromNative() {
        try {
            setupLatch.await();  // Block until setup is complete
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
    }

    public static String getDataRootPathFromNative() {
        return currentDataRootPath;
    }

    private void doVersionCheck(){
        int currentVersion = BuildConfig.VERSION_CODE;
        supportFilesNeedRefresh = !isSupportFilesMarkerCurrent() || !isSupportArchiveCurrent();
        preferences.edit().putInt("appVersion", currentVersion).apply();
    }

    private boolean isSupportArchiveCurrent() {
        File archive = new File(getTargetRootFolder(), SUPPORT_ARCHIVE);
        if (!archive.isFile() || !archiveContainsDefaultShader(archive)) {
            return false;
        }

        try (InputStream bundled = getAssets().open(SUPPORT_ARCHIVE);
             InputStream installed = new FileInputStream(archive)) {
            return Arrays.equals(digest(bundled), digest(installed));
        } catch (IOException | NoSuchAlgorithmException e) {
            Log.w("setupFiles", "Unable to verify support archive", e);
            return false;
        }
    }

    private byte[] digest(InputStream input) throws IOException, NoSuchAlgorithmException {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] buffer = new byte[64 * 1024];
        int read;
        while ((read = input.read(buffer)) != -1) {
            digest.update(buffer, 0, read);
        }
        return digest.digest();
    }

    private boolean archiveContainsDefaultShader(File archive) {
        try (ZipFile zip = new ZipFile(archive)) {
            return zip.getEntry(DEFAULT_SHADER) != null;
        } catch (IOException e) {
            return false;
        }
    }

    private File getSupportFilesMarkerFile(File targetRootFolder) {
        return new File(targetRootFolder, SUPPORT_FILES_VERSION_MARKER);
    }

    private boolean isSupportFilesMarkerCurrent() {
        File markerFile = getSupportFilesMarkerFile(getTargetRootFolder());
        if (!markerFile.exists()) {
            return false;
        }

        try (InputStream in = new java.io.FileInputStream(markerFile)) {
            byte[] buffer = new byte[(int) markerFile.length()];
            int read = in.read(buffer);
            if (read <= 0) {
                return false;
            }
            String markerVersion = new String(buffer, 0, read).trim();
            return markerVersion.equals(String.valueOf(BuildConfig.VERSION_CODE));
        } catch (IOException e) {
            Log.w("setupFiles", "Unable to read support files marker", e);
            return false;
        }
    }

    private void writeSupportFilesMarker(File targetRootFolder) throws IOException {
        File markerFile = getSupportFilesMarkerFile(targetRootFolder);
        try (OutputStream out = new FileOutputStream(markerFile)) {
            out.write(String.valueOf(BuildConfig.VERSION_CODE).getBytes());
        }
    }

    private void deleteIfExists(File file) {
        if (file.exists()) {
            if (file.delete()) {
                Log.i("deleteAssets", "Deleted file: " + file.getAbsolutePath());
            } else {
                Log.w("deleteAssets", "Failed to delete file: " + file.getAbsolutePath());
            }
        } else {
            Log.i("deleteAssets", "File not found (skipped): " + file.getAbsolutePath());
        }
    }

    private void deleteRecursiveIfExists(File dir) {
        if (dir.exists()) {
            deleteRecursive(dir);
            Log.i("deleteAssets", "Deleted directory: " + dir.getAbsolutePath());
        } else {
            Log.i("deleteAssets", "Directory not found (skipped): " + dir.getAbsolutePath());
        }
    }

    private void deleteRecursive(File fileOrDirectory) {
        if (fileOrDirectory.isDirectory()) {
            File[] children = fileOrDirectory.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursive(child);
                }
            }
        }
        fileOrDirectory.delete();
    }

    private File getTargetRootFolder() {
        String configuredPath = preferences.getString(PREF_DATA_ROOT_PATH, null);
        if (configuredPath == null || configuredPath.isEmpty()) {
            return getDefaultDataRootFolder();
        }

        return new File(configuredPath);
    }

    private File getDefaultDataRootFolder() {
        if (BuildConfig.APPLICATION_ID.equals("com.twoshipfork.mm.performancetest") ||
                BuildConfig.APPLICATION_ID.equals("com.twoshipfork.mm.performancetestci")) {
            return new File(Environment.getExternalStorageDirectory(), "2S2H-performance-test");
        }
        return new File(Environment.getExternalStorageDirectory(), "2S2H");
    }

    private void updateCurrentDataRootPath() {
        currentDataRootPath = getTargetRootFolder().getAbsolutePath();
        Log.i("setupFiles", "Current data root: " + currentDataRootPath);
    }

    private void beginSetupOrChooseDataRoot() {
        if (!preferences.contains(PREF_DATA_ROOT_PATH)) {
            preferences.edit().putString(PREF_DATA_ROOT_PATH, getDefaultDataRootFolder().getAbsolutePath()).apply();
            updateCurrentDataRootPath();
        }

        beginSetupIfStorageReady();
    }

    private static class DataRootOption {
        final String label;
        final File folder;

        DataRootOption(String label, File folder) {
            this.label = label;
            this.folder = folder;
        }
    }

    private List<DataRootOption> getDataRootOptions() {
        Map<String, DataRootOption> options = new LinkedHashMap<>();
        File defaultFolder = getDefaultDataRootFolder();
        options.put(defaultFolder.getAbsolutePath(),
                new DataRootOption("Internal storage: " + defaultFolder.getAbsolutePath(), defaultFolder));

        File[] externalDirs = getExternalFilesDirs(null);
        if (externalDirs != null) {
            for (File externalDir : externalDirs) {
                if (externalDir == null || !Environment.isExternalStorageRemovable(externalDir)) {
                    continue;
                }

                File volumeRoot = getVolumeRootFromExternalFilesDir(externalDir);
                if (volumeRoot == null) {
                    continue;
                }

                File sdFolder = new File(volumeRoot, "2S2H");
                options.put(sdFolder.getAbsolutePath(),
                        new DataRootOption("SD card: " + sdFolder.getAbsolutePath(), sdFolder));
            }
        }

        return new ArrayList<>(options.values());
    }

    private File getVolumeRootFromExternalFilesDir(File externalDir) {
        String path = externalDir.getAbsolutePath();
        String suffix = "/Android/data/" + getPackageName() + "/files";
        int suffixIndex = path.indexOf(suffix);
        if (suffixIndex > 0) {
            return new File(path.substring(0, suffixIndex));
        }

        File parent = externalDir;
        for (int i = 0; i < 4 && parent != null; i++) {
            parent = parent.getParentFile();
        }
        return parent;
    }

    private void showDataRootChooser(boolean restartRequired) {
        List<DataRootOption> options = getDataRootOptions();

        if (options.size() < 2) {
            runOnUiThread(() -> new AlertDialog.Builder(this)
                    .setTitle("Change Data Folder")
                    .setMessage("No alternate writable data folder was found. Insert or mount an SD card and try again.")
                    .setPositiveButton("OK", null)
                    .setCancelable(true)
                    .show());
            return;
        }

        runOnUiThread(() -> {
            LinearLayout layout = new LinearLayout(this);
            layout.setOrientation(LinearLayout.VERTICAL);
            int padding = (int) (20 * getResources().getDisplayMetrics().density);
            layout.setPadding(padding, padding, padding, padding);

            TextView message = new TextView(this);
            message.setText("Choose where 2S2H stores saves, mods, settings, and support files.");
            message.setTextColor(Color.BLACK);
            layout.addView(message);

            AlertDialog dialog = new AlertDialog.Builder(this)
                    .setTitle("Change Data Folder")
                    .setView(layout)
                    .setNegativeButton("Cancel", null)
                    .setCancelable(true)
                    .create();

            for (DataRootOption option : options) {
                Button optionButton = new Button(this);
                optionButton.setAllCaps(false);
                optionButton.setText(option.label);
                optionButton.setTextColor(Color.BLACK);
                optionButton.setOnClickListener((view) -> {
                    dialog.dismiss();
                    Executors.newSingleThreadExecutor()
                            .execute(() -> applyDataRootSelection(option.folder, restartRequired));
                });
                layout.addView(optionButton);
            }

            dialog.show();
        });
    }

    private void applyDataRootSelection(File targetRootFolder, boolean restartRequired) {
        File previousRoot = getTargetRootFolder();
        Log.i("setupFiles", "Changing data root from " + previousRoot.getAbsolutePath() +
                " to " + targetRootFolder.getAbsolutePath());
        preferences.edit().putString(PREF_DATA_ROOT_PATH, targetRootFolder.getAbsolutePath()).apply();
        updateCurrentDataRootPath();

        if (!ensureTargetRootFolderReady(targetRootFolder)) {
            preferences.edit().putString(PREF_DATA_ROOT_PATH, previousRoot.getAbsolutePath()).apply();
            updateCurrentDataRootPath();
            showSetupFailure("The selected data folder is not writable.");
            return;
        }

        boolean willMigrateData = shouldMigrateExistingRoot(previousRoot, targetRootFolder) ||
                shouldMigrateExistingRoot(getDefaultDataRootFolder(), targetRootFolder);
        if (willMigrateData) {
            showDataRootMigrationDialog();
        }
        migrateExistingRootIfNeeded(previousRoot, targetRootFolder);
        migrateExistingRootIfNeeded(getDefaultDataRootFolder(), targetRootFolder);
        if (willMigrateData) {
            dismissDataRootMigrationDialog();
        }

        if (restartRequired) {
            runOnUiThread(() -> new AlertDialog.Builder(this)
                    .setTitle("Restart Required")
                    .setMessage("2S2H will use the new data folder after restarting. Existing data was copied when needed; the old folder was left in place.")
                    .setCancelable(false)
                    .setPositiveButton("Close App", (dialog, which) -> finish())
                    .show());
            return;
        }

        beginSetupIfStorageReady();
    }

    private void showDataRootMigrationDialog() {
        runOnUiThread(() -> {
            if (dataRootMigrationDialog != null && dataRootMigrationDialog.isShowing()) {
                return;
            }

            LinearLayout layout = new LinearLayout(this);
            layout.setOrientation(LinearLayout.VERTICAL);
            int padding = (int) (20 * getResources().getDisplayMetrics().density);
            layout.setPadding(padding, padding, padding, padding);

            ProgressBar progressBar = new ProgressBar(this);
            progressBar.setIndeterminate(true);
            layout.addView(progressBar);

            TextView message = new TextView(this);
            message.setText("Copying saves, mods, settings, and support files. This may take a few minutes.");
            message.setTextColor(Color.BLACK);
            layout.addView(message);

            dataRootMigrationDialog = new AlertDialog.Builder(this)
                    .setTitle("Moving Data Folder")
                    .setView(layout)
                    .setCancelable(false)
                    .create();
            dataRootMigrationDialog.show();
        });
    }

    private void dismissDataRootMigrationDialog() {
        runOnUiThread(() -> {
            if (dataRootMigrationDialog != null && dataRootMigrationDialog.isShowing()) {
                dataRootMigrationDialog.dismiss();
            }
            dataRootMigrationDialog = null;
        });
    }

    private void showSetupProgressDialog(String title, String text) {
        runOnUiThread(() -> {
            if (setupProgressDialog != null && setupProgressDialog.isShowing()) {
                return;
            }

            LinearLayout layout = new LinearLayout(this);
            layout.setOrientation(LinearLayout.VERTICAL);
            int padding = (int) (20 * getResources().getDisplayMetrics().density);
            layout.setPadding(padding, padding, padding, padding);

            ProgressBar progressBar = new ProgressBar(this);
            progressBar.setIndeterminate(true);
            layout.addView(progressBar);

            TextView message = new TextView(this);
            message.setText(text);
            message.setTextColor(Color.BLACK);
            layout.addView(message);

            setupProgressDialog = new AlertDialog.Builder(this)
                    .setTitle(title)
                    .setView(layout)
                    .setCancelable(false)
                    .create();
            setupProgressDialog.show();
        });
    }

    private void dismissSetupProgressDialog() {
        runOnUiThread(() -> {
            if (setupProgressDialog != null && setupProgressDialog.isShowing()) {
                setupProgressDialog.dismiss();
            }
            setupProgressDialog = null;
        });
    }

    private void migrateExistingRootIfNeeded(File sourceRoot, File targetRoot) {
        if (!shouldMigrateExistingRoot(sourceRoot, targetRoot)) {
            return;
        }

        try {
            Log.i("setupFiles", "Copying existing data from " + sourceRoot.getAbsolutePath() +
                    " to " + targetRoot.getAbsolutePath());
            AssetCopyUtil.copyDirectoryContentsNoOverwrite(sourceRoot, targetRoot);
            Log.i("setupFiles", "Copied existing data from: " + sourceRoot.getAbsolutePath());
        } catch (IOException e) {
            Log.e("setupFiles", "Failed to copy existing data from: " + sourceRoot.getAbsolutePath(), e);
            runOnUiThread(() -> Toast.makeText(this, "Could not copy existing data", Toast.LENGTH_LONG).show());
        }
    }

    private boolean shouldMigrateExistingRoot(File sourceRoot, File targetRoot) {
        return sourceRoot != null && targetRoot != null &&
                !sourceRoot.getAbsolutePath().equals(targetRoot.getAbsolutePath()) &&
                sourceRoot.isDirectory() && isDirectoryEmpty(targetRoot);
    }

    private boolean isDirectoryEmpty(File directory) {
        File[] files = directory.listFiles();
        return files == null || files.length == 0;
    }

    private void beginSetupIfStorageReady() {
        updateCurrentDataRootPath();
        File targetRootFolder = getTargetRootFolder();
        Log.i("setupFiles", "Beginning setup for data root: " + targetRootFolder.getAbsolutePath());
        if (!ensureTargetRootFolderReady(targetRootFolder)) {
            showStorageAccessFailure();
            return;
        }

        if (recoverWithoutMods) {
            File safeModeMarker = new File(targetRootFolder, SAFE_MODE_MARKER);
            try (OutputStream out = new FileOutputStream(safeModeMarker, false)) {
                out.write(String.valueOf(System.currentTimeMillis()).getBytes());
                Toast.makeText(this, "Previous startup failed. Mods will be skipped once.", Toast.LENGTH_LONG).show();
            } catch (IOException e) {
                Log.w("setupFiles", "Unable to enable recovery startup", e);
            }
            recoverWithoutMods = false;
        }

        doVersionCheck();
        checkAndSetupFiles();
    }

    // Check if storage permission is granted
    private boolean hasStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager();
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true;
        }

        return ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE)
                == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)
                        == PackageManager.PERMISSION_GRANTED;
    }

    private boolean ensureTargetRootFolderReady(File targetRootFolder) {
        if (!isExternalStorageWritable() || !hasStoragePermission()) {
            return false;
        }

        if (!targetRootFolder.exists() && !targetRootFolder.mkdirs()) {
            Log.e("setupFiles", "Failed to create root folder: " + targetRootFolder.getAbsolutePath());
            return false;
        }

        if (!targetRootFolder.isDirectory() || !targetRootFolder.canWrite()) {
            Log.e("setupFiles", "Root folder is not writable: " + targetRootFolder.getAbsolutePath());
            return false;
        }

        File probeFile = new File(targetRootFolder, ".write_test");
        try (OutputStream out = new FileOutputStream(probeFile)) {
            out.write(0);
        } catch (IOException e) {
            Log.e("setupFiles", "Write probe failed for: " + targetRootFolder.getAbsolutePath(), e);
            return false;
        }

        if (probeFile.exists() && !probeFile.delete()) {
            Log.w("setupFiles", "Failed to delete write probe: " + probeFile.getAbsolutePath());
        }

        return true;
    }

    private static final int STORAGE_PERMISSION_REQUEST_CODE = 2296;
    private static final int FILE_PICKER_REQUEST_CODE = 0;

    private void requestStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11+ → MANAGE_EXTERNAL_STORAGE
            if (!Environment.isExternalStorageManager()) {
                Intent intent = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                intent.setData(Uri.parse("package:" + getPackageName()));
                startActivityForResult(intent, STORAGE_PERMISSION_REQUEST_CODE);
            } else {
                beginSetupOrChooseDataRoot();
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            // Android 6–10 → request READ/WRITE at runtime
            ActivityCompat.requestPermissions(this,
                    new String[]{
                            Manifest.permission.READ_EXTERNAL_STORAGE,
                            Manifest.permission.WRITE_EXTERNAL_STORAGE
                    },
                    STORAGE_PERMISSION_REQUEST_CODE);
        } else {
            // Below Android 6 → permissions granted at install time
            beginSetupOrChooseDataRoot();
        }
    }

    public void checkAndSetupFiles() {
        File targetRootFolder = getTargetRootFolder();
        File assetsFolder = new File(targetRootFolder, "assets");
        File shipOtrFile = new File(targetRootFolder, "2ship.o2r");

        boolean isMissingAssets = !assetsFolder.exists() || assetsFolder.listFiles() == null || assetsFolder.listFiles().length == 0;
        boolean isMissingShipOtr = !shipOtrFile.exists();

        if (!targetRootFolder.exists() || isMissingAssets || isMissingShipOtr || supportFilesNeedRefresh) {
            new AlertDialog.Builder(this)
                    .setTitle("Setup Required")
                    .setMessage("Some required files are missing. The app will create them now. This can take a few minutes on SD cards.")
                    .setCancelable(false)
                    .setPositiveButton("OK", (dialog, which) -> {
                        Executors.newSingleThreadExecutor().execute(() -> {
                            showSetupProgressDialog("Preparing Data Folder",
                                    "Copying required support files. Please keep 2S2H open; SD cards may take a few minutes.");
                            setupFilesInBackground(targetRootFolder);
                        });
                    })
                    .show();
        } else {
            // No setup needed, still need to count down
            setupLatch.countDown();
        }
    }


    private void setupFilesInBackground(File targetRootFolder) {
        boolean setupFailed = false;
        Log.i("setupFiles", "Copying support files to: " + targetRootFolder.getAbsolutePath());

        if (!ensureTargetRootFolderReady(targetRootFolder)) {
            dismissSetupProgressDialog();
            showStorageAccessFailure();
            return;
        }

        migrateLegacyAppDataIfNeeded(targetRootFolder);

        // Ensure root folder exists
        if (!targetRootFolder.exists()) {
            if (!targetRootFolder.mkdirs()) {
                Log.e("setupFiles", "Failed to create root folder");
                dismissSetupProgressDialog();
                showSetupFailure("Failed to create the 2S2H folder.");
                return;
            }
        }

        // Always ensure mods folder exists
        File targetModsDir = new File(targetRootFolder, "mods");
        if (!targetModsDir.exists() && !targetModsDir.mkdirs()) {
            dismissSetupProgressDialog();
            showSetupFailure("Failed to create the mods folder.");
            return;
        }

        // Copy assets/ from internal
        File targetAssetsDir = new File(targetRootFolder, "assets");
        try {
            if (supportFilesNeedRefresh) {
                deleteRecursiveIfExists(targetAssetsDir);
            }
            if (!targetAssetsDir.exists() && !targetAssetsDir.mkdirs()) {
                throw new IOException("Failed to create assets folder: " + targetAssetsDir.getAbsolutePath());
            }
            AssetCopyUtil.copyAssetsToExternal(this, "assets", targetAssetsDir.getAbsolutePath());
            runOnUiThread(() -> Toast.makeText(this, "Assets copied", Toast.LENGTH_SHORT).show());
        } catch (IOException e) {
            e.printStackTrace();
            setupFailed = true;
            runOnUiThread(() -> Toast.makeText(this, "Error copying assets", Toast.LENGTH_LONG).show());
        }

        File targetShipOtrFile = new File(targetRootFolder, SUPPORT_ARCHIVE);
        File temporaryShipOtrFile = new File(targetRootFolder, SUPPORT_ARCHIVE + ".new");
        try {
            try (InputStream in = getAssets().open(SUPPORT_ARCHIVE);
                 FileOutputStream out = new FileOutputStream(temporaryShipOtrFile, false)) {
                byte[] buffer = new byte[64 * 1024];
                int read;
                while ((read = in.read(buffer)) != -1) {
                    out.write(buffer, 0, read);
                }
                out.getFD().sync();
            }
            if (!archiveContainsDefaultShader(temporaryShipOtrFile)) {
                throw new IOException("Bundled support archive is missing the default shader");
            }
            replaceSupportArchive(temporaryShipOtrFile, targetShipOtrFile);
            runOnUiThread(() -> Toast.makeText(this, "Support archive copied", Toast.LENGTH_SHORT).show());
        } catch (IOException e) {
            e.printStackTrace();
            setupFailed = true;
            runOnUiThread(() -> Toast.makeText(this, "Error copying support archive", Toast.LENGTH_LONG).show());
        }

        if (setupFailed) {
            dismissSetupProgressDialog();
            showSetupFailure("Required support files could not be copied. Please install a complete APK build.");
            return;
        }

        try {
            writeSupportFilesMarker(targetRootFolder);
        } catch (IOException e) {
            Log.e("setupFiles", "Failed to write support files marker", e);
            dismissSetupProgressDialog();
            showSetupFailure("Required support files could not be finalized.");
            return;
        }

        dismissSetupProgressDialog();
        supportFilesNeedRefresh = false;
        setupLatch.countDown();
    }

    private void replaceSupportArchive(File replacement, File target) throws IOException {
        File backup = new File(target.getParentFile(), target.getName() + ".old");
        deleteIfExists(backup);

        if (target.exists() && !target.renameTo(backup)) {
            throw new IOException("Unable to preserve the existing support archive");
        }
        if (!replacement.renameTo(target)) {
            if (backup.exists() && !backup.renameTo(target)) {
                Log.e("setupFiles", "Unable to restore the previous support archive");
            }
            throw new IOException("Unable to activate the new support archive");
        }
        deleteIfExists(backup);
    }

    private void migrateLegacyAppDataIfNeeded(File targetRootFolder) {
        if (preferences.getBoolean(PREF_LEGACY_DATA_MIGRATION_COMPLETE, false)) {
            return;
        }

        File sourceOldRoot = getExternalFilesDir(null);
        File sourceSavesDir = sourceOldRoot == null ? null : new File(sourceOldRoot, "saves");
        if (sourceOldRoot == null || sourceSavesDir == null || !sourceSavesDir.isDirectory()) {
            preferences.edit().putBoolean(PREF_LEGACY_DATA_MIGRATION_COMPLETE, true).apply();
            return;
        }

        Log.i("setupFiles", "Migrating old data without overwriting current files: " + sourceOldRoot.getAbsolutePath());

        File[] sourceFiles = sourceOldRoot.listFiles();
        if (sourceFiles != null) {
            for (File file : sourceFiles) {
                String name = file.getName();
                if (name.equals("assets") || name.equals("2ship.o2r") || name.equals("mm.o2r")) {
                    continue;
                }

                File dest = new File(targetRootFolder, name);
                try {
                    if (file.isDirectory()) {
                        AssetCopyUtil.copyDirectoryNoOverwrite(file, dest);
                    } else {
                        AssetCopyUtil.copyFileNoOverwrite(file, dest);
                    }
                    Log.i("setupFiles", "Migrated missing legacy data: " + name);
                } catch (IOException e) {
                    Log.e("setupFiles", "Failed to migrate legacy data: " + name, e);
                }
            }
        }

        preferences.edit().putBoolean(PREF_LEGACY_DATA_MIGRATION_COMPLETE, true).apply();
        runOnUiThread(() -> Toast.makeText(this, "Existing save data checked", Toast.LENGTH_SHORT).show());
    }

    private void showSetupFailure(String message) {
        runOnUiThread(() -> new AlertDialog.Builder(this)
                .setTitle("Setup Failed")
                .setMessage(message)
                .setCancelable(false)
                .setPositiveButton("Close", (dialog, which) -> finish())
                .show());
    }




    private native void nativeHandleSelectedFile(String filePath);

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);

        if (requestCode == FILE_PICKER_REQUEST_CODE && resultCode == RESULT_OK && data != null) {
            // Handle file selection
            Uri selectedFileUri = data.getData();
            String fileName = "MM.z64";

            File destinationDirectory = getTargetRootFolder();
            File destinationFile = new File(destinationDirectory, fileName);

            if (selectedFileUri != null && ensureTargetRootFolderReady(destinationDirectory)) {
                try {
                    InputStream in = getContentResolver().openInputStream(selectedFileUri);
                    OutputStream out = new FileOutputStream(destinationFile);

                    byte[] buffer = new byte[4096];
                    int bytesRead;
                    while ((bytesRead = in.read(buffer)) != -1) {
                        out.write(buffer, 0, bytesRead);
                    }

                    in.close();
                    out.close();
                } catch (IOException e) {
                    e.printStackTrace();
                    showSetupFailure("The selected file could not be copied into the 2S2H folder.");
                    return;
                }
            } else {
                showStorageAccessFailure();
                return;
            }

            // Now pass the path of the file in the new folder
            nativeHandleSelectedFile(destinationFile.getPath());

        } else if (requestCode == STORAGE_PERMISSION_REQUEST_CODE) {
            // Handle MANAGE_EXTERNAL_STORAGE result
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                if (Environment.isExternalStorageManager()) {
                    beginSetupOrChooseDataRoot();
                } else {
                    Toast.makeText(this, "Storage permission is required to access files.", Toast.LENGTH_LONG).show();
                }
            }
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);

        if (requestCode == STORAGE_PERMISSION_REQUEST_CODE) {
            if (hasStoragePermission()) {
                beginSetupOrChooseDataRoot();
            } else {
                showStorageAccessFailure();
            }
        }
    }

    private void showStorageAccessFailure() {
        runOnUiThread(() -> new AlertDialog.Builder(this)
                .setTitle("Storage Permission Required")
                .setMessage("The app needs file access to create and update the 2S2H folder. Please grant storage access and try again.")
                .setCancelable(false)
                .setPositiveButton("Open Settings", (dialog, which) -> requestStoragePermission())
                .setNegativeButton("Close", (dialog, which) -> finish())
                .show());
    }


    public void openFilePicker() {
        // Create an Intent to open the file picker dialog
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.setType("*/*");

        // Start the file picker dialog
        startActivityForResult(intent, 0);
    }

    public void changeDataFolderFromNative() {
        showDataRootChooser(true);
    }

    public String getAndroidVersionFromNative() {
        String release = Build.VERSION.RELEASE;
        if (release == null || release.isEmpty()) {
            return "Android API " + Build.VERSION.SDK_INT;
        }

        return "Android " + release + " (API " + Build.VERSION.SDK_INT + ")";
    }

    // Check if external storage is available and writable
    private boolean isExternalStorageWritable() {
        String state = Environment.getExternalStorageState();
        return Environment.MEDIA_MOUNTED.equals(state);
    }


    public native void attachController();
    public native void detachController();
    public native void nativeGamepadBackPressed();
    // Native method for setting button state
    public native void setButton(int button, boolean value);
    public native void setCameraState(int axis, float value);

    // Native method for setting joystick axis value
    public native void setAxis(int axis, short value);

    private Button button1, button2, button3, button4;
    private Button buttonA, buttonB, buttonX, buttonY;
    private Button buttonDpadUp, buttonDpadDown, buttonDpadLeft, buttonDpadRight;
    private Button buttonLB, buttonRB, buttonZL, buttonZR, buttonStart, buttonBack;
    private Button buttonToggle;
    private FrameLayout leftJoystick;
    private ImageView leftJoystickKnob;
    private View overlayView;
    private ViewGroup buttonGroup;
    private int leftStickPointerId = MotionEvent.INVALID_POINTER_ID;
    private int rightStickPointerId = MotionEvent.INVALID_POINTER_ID;
    private float leftStickStartX;
    private float leftStickStartY;
    private float leftStickFixedX = Float.NaN;
    private float leftStickFixedY = Float.NaN;
    private float rightStickStartX;
    private float rightStickStartY;

    // Function to set up the controller overlay (inflate layout and initialize buttons)
    private void setupControllerOverlay() {
        View contentView = getContentView();
        if (!(contentView instanceof ViewGroup)) {
            Log.e("MainActivity", "SDL content view is unavailable; skipping controller overlay setup");
            return;
        }

        // Inflate the touchcontrol_overlay layout
        LayoutInflater inflater = (LayoutInflater) getSystemService(LAYOUT_INFLATER_SERVICE);
        overlayView = inflater.inflate(R.layout.touchcontrol_overlay, null);

        // Set layout params for overlayView to control positioning and sizing
        FrameLayout.LayoutParams layoutParams = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
        );
        overlayView.setLayoutParams(layoutParams);
        // Add overlay view to the main layout (you may need to add it to a container like FrameLayout)
        ViewGroup view = (ViewGroup) contentView;
        view.addView(overlayView);

        buttonGroup = overlayView.findViewById(R.id.button_group);

        buttonA = overlayView.findViewById(R.id.buttonA);
        buttonB = overlayView.findViewById(R.id.buttonB);
        buttonX = overlayView.findViewById(R.id.buttonX);
        buttonY = overlayView.findViewById(R.id.buttonY);
        applyTouchFaceButtonLayout(preferences.getInt(
                PREF_TOUCH_FACE_BUTTON_LAYOUT, TOUCH_FACE_BUTTON_LAYOUT_ABXY));

        buttonDpadUp = overlayView.findViewById(R.id.buttonDpadUp);
        buttonDpadDown = overlayView.findViewById(R.id.buttonDpadDown);
        buttonDpadLeft = overlayView.findViewById(R.id.buttonDpadLeft);
        buttonDpadRight = overlayView.findViewById(R.id.buttonDpadRight);

        buttonLB = overlayView.findViewById(R.id.buttonLB);
        buttonRB = overlayView.findViewById(R.id.buttonRB);
        buttonZL = overlayView.findViewById(R.id.buttonZL);
        buttonZR = overlayView.findViewById(R.id.buttonZR);

        buttonStart = overlayView.findViewById(R.id.buttonStart);
        buttonBack = overlayView.findViewById(R.id.buttonBack);

        buttonToggle = overlayView.findViewById(R.id.buttonToggle);

        // Initialize joysticks and joystick knobs from the inflated layout
        leftJoystick = overlayView.findViewById(R.id.left_joystick);
        leftJoystickKnob = overlayView.findViewById(R.id.left_joystick_knob);

        FrameLayout leftScreenArea = overlayView.findViewById(R.id.left_screen_area);
        FrameLayout rightScreenArea = overlayView.findViewById(R.id.right_screen_area);

        // Set OnTouchListeners for the Xbox controller buttons
        addTouchListener(buttonA, ControllerButtons.BUTTON_A); // SDL Button 0 (A)
        addTouchListener(buttonB, ControllerButtons.BUTTON_B); // SDL Button 1 (B)
        addTouchListener(buttonX, ControllerButtons.BUTTON_X); // SDL Button 2 (X)
        addTouchListener(buttonY, ControllerButtons.BUTTON_Y); // SDL Button 3 (Y)

        setupCButtons(buttonDpadUp, ControllerButtons.BUTTON_DPAD_UP);
        setupCButtons(buttonDpadDown, ControllerButtons.BUTTON_DPAD_DOWN);
        setupCButtons(buttonDpadLeft, ControllerButtons.BUTTON_DPAD_LEFT);
        setupCButtons(buttonDpadRight, ControllerButtons.BUTTON_DPAD_RIGHT);

        addTouchListener(buttonLB, ControllerButtons.BUTTON_LB); // SDL Button 4 (LB)
        addTouchListener(buttonRB, ControllerButtons.BUTTON_RB); // SDL Button 5 (RB)
        addTouchListener(buttonZL, ControllerButtons.AXIS_LT);
        addTouchListener(buttonZR, ControllerButtons.AXIS_RT);

        addTouchListener(buttonStart, ControllerButtons.BUTTON_START); // SDL Button 7 (Start)
        // Send touch Back directly to the menu. ImGui may be polling a physical
        // controller instead of the touch overlay's virtual SDL controller.
        buttonBack.setOnTouchListener((v, event) -> {
            if (event.getAction() == MotionEvent.ACTION_DOWN) {
                nativeGamepadBackPressed();
            }
            return true;
        });


        setupFloatingJoystick(leftScreenArea);
        setupLookAround(rightScreenArea);

        setupToggleButton(buttonToggle,buttonGroup);
        applyTouchLeftStickMode();
        applyTouchControlsVisibility();

    }

    public void setTouchControlsDisabledFromNative(boolean disabled) {
        preferences.edit().putBoolean(PREF_TOUCH_CONTROLS_DISABLED, disabled).apply();
        runOnUiThread(this::applyTouchControlsVisibility);
    }

    public void setTouchFaceButtonLayoutFromNative(int layout) {
        int normalizedLayout = layout >= TOUCH_FACE_BUTTON_LAYOUT_ABXY &&
                layout <= TOUCH_FACE_BUTTON_LAYOUT_GAMECUBE
                ? layout : TOUCH_FACE_BUTTON_LAYOUT_ABXY;
        preferences.edit().putInt(PREF_TOUCH_FACE_BUTTON_LAYOUT, normalizedLayout).apply();
        runOnUiThread(() -> applyTouchFaceButtonLayout(normalizedLayout));
    }

    public void setTouchLeftStickFloatingFromNative(boolean floating) {
        preferences.edit().putBoolean(PREF_TOUCH_LEFT_STICK_FLOATING, floating).apply();
        runOnUiThread(this::applyTouchLeftStickMode);
    }

    private void applyTouchLeftStickMode() {
        if (leftJoystick == null) {
            return;
        }
        boolean floating = preferences.getBoolean(PREF_TOUCH_LEFT_STICK_FLOATING, true);
        if (!floating && !Float.isNaN(leftStickFixedX)) {
            leftJoystick.setX(leftStickFixedX);
            leftJoystick.setY(leftStickFixedY);
            leftJoystickKnob.setX(leftJoystick.getWidth() / 2.0f - leftJoystickKnob.getWidth() / 2.0f);
            leftJoystickKnob.setY(leftJoystick.getHeight() / 2.0f - leftJoystickKnob.getHeight() / 2.0f);
        }
        leftJoystick.setVisibility(floating ? View.INVISIBLE : View.VISIBLE);
    }

    private void applyTouchFaceButtonLayout(int layout) {
        if (buttonA == null || buttonB == null || buttonX == null || buttonY == null) {
            return;
        }

        FrameLayout actionButtonCluster = overlayView.findViewById(R.id.action_button_cluster);
        if (layout == TOUCH_FACE_BUTTON_LAYOUT_GAMECUBE) {
            setViewSize(actionButtonCluster, 200, 170);
            configureFaceButton(buttonA, 70, 70, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL, 20, 0, 0, 20);
            configureFaceButton(buttonB, 46, 46, Gravity.BOTTOM | Gravity.START, 30, 0, 0, 20);
            configureFaceButton(buttonX, 46, 46, Gravity.TOP | Gravity.END, 0, 37, 0, 0);
            configureFaceButton(buttonY, 46, 46, Gravity.TOP | Gravity.CENTER_HORIZONTAL, 0, 15, 0, 0);
        } else if (layout == TOUCH_FACE_BUTTON_LAYOUT_BAYX) {
            setViewSize(actionButtonCluster, 132, 132);
            configureFaceButton(buttonA, 44, 44, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL, 0, 0, 0, 0);
            configureFaceButton(buttonB, 44, 44, Gravity.CENTER_VERTICAL | Gravity.END, 0, 0, 0, 0);
            configureFaceButton(buttonX, 44, 44, Gravity.CENTER_VERTICAL | Gravity.START, 0, 0, 0, 0);
            configureFaceButton(buttonY, 44, 44, Gravity.TOP | Gravity.CENTER_HORIZONTAL, 0, 0, 0, 0);
        } else {
            setViewSize(actionButtonCluster, 132, 132);
            configureFaceButton(buttonB, 44, 44, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL, 0, 0, 0, 0);
            configureFaceButton(buttonA, 44, 44, Gravity.CENTER_VERTICAL | Gravity.END, 0, 0, 0, 0);
            configureFaceButton(buttonY, 44, 44, Gravity.CENTER_VERTICAL | Gravity.START, 0, 0, 0, 0);
            configureFaceButton(buttonX, 44, 44, Gravity.TOP | Gravity.CENTER_HORIZONTAL, 0, 0, 0, 0);
        }
    }

    private void configureFaceButton(Button button, int widthDp, int heightDp, int gravity,
                                     int marginStartDp, int marginTopDp,
                                     int marginEndDp, int marginBottomDp) {
        FrameLayout.LayoutParams params = (FrameLayout.LayoutParams) button.getLayoutParams();
        params.width = dpToPixels(widthDp);
        params.height = dpToPixels(heightDp);
        params.gravity = gravity;
        int marginStart = dpToPixels(marginStartDp);
        int marginEnd = dpToPixels(marginEndDp);
        params.setMargins(marginStart, dpToPixels(marginTopDp), marginEnd, dpToPixels(marginBottomDp));
        params.setMarginStart(marginStart);
        params.setMarginEnd(marginEnd);
        button.setLayoutParams(params);
    }

    private void setViewSize(View view, int widthDp, int heightDp) {
        ViewGroup.LayoutParams params = view.getLayoutParams();
        params.width = dpToPixels(widthDp);
        params.height = dpToPixels(heightDp);
        view.setLayoutParams(params);
    }

    private int dpToPixels(float dp) {
        return Math.round(dp * getResources().getDisplayMetrics().density);
    }

    private void setTouchButtonPressed(Button button, boolean pressed) {
        button.setPressed(pressed);
        float scale = pressed ? 0.92f : 1.0f;
        button.animate().scaleX(scale).scaleY(scale).setDuration(60).start();
    }

    private void applyTouchControlsVisibility() {
        if (overlayView == null) {
            return;
        }

        boolean touchControlsDisabled = preferences.getBoolean(PREF_TOUCH_CONTROLS_DISABLED, false);
        overlayView.setVisibility(touchControlsDisabled ? View.GONE : View.VISIBLE);

        if (buttonGroup != null) {
            boolean controlsHidden = preferences.getBoolean(PREF_TOUCH_CONTROLS_HIDDEN, false);
            buttonGroup.setVisibility(controlsHidden ? View.INVISIBLE : View.VISIBLE);
        }
    }

    private void setupToggleButton(Button button, ViewGroup uiGroup){
        button.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                boolean controlsHidden = uiGroup.getVisibility() == View.VISIBLE;
                preferences.edit().putBoolean(PREF_TOUCH_CONTROLS_HIDDEN, controlsHidden).apply();
                applyTouchControlsVisibility();
            }
        });
    }

    // Function to set a touch listener for each button
    private void addTouchListener(Button button, int buttonNum) {
        button.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent event) {
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                        setButton(buttonNum, true);
                        setTouchButtonPressed(button, true);
                        return true;
                    case MotionEvent.ACTION_UP:
                        setButton(buttonNum, false);
                        setTouchButtonPressed(button, false);
                        return true;
                    case MotionEvent.ACTION_CANCEL:
                        setButton(buttonNum, false);
                        setTouchButtonPressed(button, false);
                        return true;
                }
                return false;
            }
        });
    }

    private void setupCButtons(Button button, int buttonNum) {
        button.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent event) {
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                        setButton(buttonNum, true);
                        setTouchButtonPressed(button, true);
                        return true;
                    case MotionEvent.ACTION_UP:
                        setButton(buttonNum, false);
                        setTouchButtonPressed(button, false);
                        return true;
                    case MotionEvent.ACTION_CANCEL:
                        setButton(buttonNum, false);
                        setTouchButtonPressed(button, false);
                        return true;
                }
                return false;
            }
        });
    }

    boolean TouchAreaEnabled = true;

    void DisableTouchArea(){
        TouchAreaEnabled = false;
    }
    void EnableTouchArea(){
        TouchAreaEnabled = true;
    }

    private void setupFloatingJoystick(FrameLayout touchArea) {
        final float maxRadius = dpToPixels(51);
        leftJoystick.post(() -> {
            leftStickFixedX = leftJoystick.getX();
            leftStickFixedY = leftJoystick.getY();
            applyTouchLeftStickMode();
        });
        touchArea.setOnTouchListener((view, event) -> {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    boolean floating = preferences.getBoolean(PREF_TOUCH_LEFT_STICK_FLOATING, true);
                    if (floating) {
                        leftStickStartX = event.getX();
                        leftStickStartY = event.getY();
                        leftJoystick.setX(leftStickStartX - leftJoystick.getWidth() / 2.0f);
                        leftJoystick.setY(leftStickStartY - leftJoystick.getHeight() / 2.0f);
                    } else {
                        leftStickStartX = leftJoystick.getX() + leftJoystick.getWidth() / 2.0f;
                        leftStickStartY = leftJoystick.getY() + leftJoystick.getHeight() / 2.0f;
                    }
                    leftJoystickKnob.setX(leftJoystick.getWidth() / 2.0f - leftJoystickKnob.getWidth() / 2.0f);
                    leftJoystickKnob.setY(leftJoystick.getHeight() / 2.0f - leftJoystickKnob.getHeight() / 2.0f);
                    leftJoystick.setVisibility(View.VISIBLE);
                    return true;
                case MotionEvent.ACTION_MOVE:
                    float deltaX = event.getX() - leftStickStartX;
                    float deltaY = event.getY() - leftStickStartY;
                    float distance = (float) Math.sqrt(deltaX * deltaX + deltaY * deltaY);
                    if (distance > maxRadius && distance > 0.0f) {
                        float scale = maxRadius / distance;
                        deltaX *= scale;
                        deltaY *= scale;
                    }
                    leftJoystickKnob.setX(leftJoystick.getWidth() / 2.0f + deltaX -
                            leftJoystickKnob.getWidth() / 2.0f);
                    leftJoystickKnob.setY(leftJoystick.getHeight() / 2.0f + deltaY -
                            leftJoystickKnob.getHeight() / 2.0f);
                    setAxis(ControllerButtons.AXIS_LX, (short) (deltaX / maxRadius * Short.MAX_VALUE));
                    setAxis(ControllerButtons.AXIS_LY, (short) (deltaY / maxRadius * Short.MAX_VALUE));
                    return true;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    setAxis(ControllerButtons.AXIS_LX, (short) 0);
                    setAxis(ControllerButtons.AXIS_LY, (short) 0);
                    if (preferences.getBoolean(PREF_TOUCH_LEFT_STICK_FLOATING, true)) {
                        leftJoystick.setVisibility(View.INVISIBLE);
                    }
                    return true;
                default:
                    return true;
            }
        });
    }

    private void setupTouchAreas(FrameLayout touchArea) {
        final float leftMaxRadius = dpToPixels(51);
        leftJoystick.setVisibility(View.INVISIBLE);
        touchArea.setOnTouchListener((view, event) -> {
            if (!TouchAreaEnabled) {
                return false;
            }
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                case MotionEvent.ACTION_POINTER_DOWN:
                    return startTouchAreaPointer(view, event, event.getActionIndex());
                case MotionEvent.ACTION_MOVE:
                    updateTouchAreaPointers(event, leftMaxRadius);
                    return leftStickPointerId != MotionEvent.INVALID_POINTER_ID ||
                            rightStickPointerId != MotionEvent.INVALID_POINTER_ID;
                case MotionEvent.ACTION_POINTER_UP:
                case MotionEvent.ACTION_UP:
                    releaseTouchAreaPointer(event.getPointerId(event.getActionIndex()));
                    return true;
                case MotionEvent.ACTION_CANCEL:
                    resetLeftStick();
                    resetRightTouch();
                    return true;
                default:
                    return true;
            }
        });
    }

    private boolean startTouchAreaPointer(View view, MotionEvent event, int pointerIndex) {
        float x = event.getX(pointerIndex);
        float y = event.getY(pointerIndex);
        int pointerId = event.getPointerId(pointerIndex);
        if (x < view.getWidth() * 0.46f && leftStickPointerId == MotionEvent.INVALID_POINTER_ID) {
            leftStickPointerId = pointerId;
            leftStickStartX = x;
            leftStickStartY = y;
            leftJoystick.setX(x - leftJoystick.getWidth() / 2.0f);
            leftJoystick.setY(y - leftJoystick.getHeight() / 2.0f);
            leftJoystickKnob.setX(leftJoystick.getWidth() / 2.0f - leftJoystickKnob.getWidth() / 2.0f);
            leftJoystickKnob.setY(leftJoystick.getHeight() / 2.0f - leftJoystickKnob.getHeight() / 2.0f);
            leftJoystick.setVisibility(View.VISIBLE);
            return true;
        }
        if (x > view.getWidth() * 0.52f && rightStickPointerId == MotionEvent.INVALID_POINTER_ID) {
            rightStickPointerId = pointerId;
            rightStickStartX = x;
            rightStickStartY = y;
            return true;
        }
        return false;
    }

    private void updateTouchAreaPointers(MotionEvent event, float leftMaxRadius) {
        int leftIndex = event.findPointerIndex(leftStickPointerId);
        if (leftIndex >= 0) {
            float deltaX = event.getX(leftIndex) - leftStickStartX;
            float deltaY = event.getY(leftIndex) - leftStickStartY;
            float distance = (float) Math.sqrt(deltaX * deltaX + deltaY * deltaY);
            if (distance > leftMaxRadius && distance > 0.0f) {
                float scale = leftMaxRadius / distance;
                deltaX *= scale;
                deltaY *= scale;
            }
            leftJoystickKnob.setX(leftJoystick.getWidth() / 2.0f + deltaX -
                    leftJoystickKnob.getWidth() / 2.0f);
            leftJoystickKnob.setY(leftJoystick.getHeight() / 2.0f + deltaY -
                    leftJoystickKnob.getHeight() / 2.0f);
            setAxis(ControllerButtons.AXIS_LX, (short) (deltaX / leftMaxRadius * Short.MAX_VALUE));
            setAxis(ControllerButtons.AXIS_LY, (short) (deltaY / leftMaxRadius * Short.MAX_VALUE));
        }

        int rightIndex = event.findPointerIndex(rightStickPointerId);
        if (rightIndex >= 0) {
            setCameraState(0, clampTouchCamera(
                    (event.getX(rightIndex) - rightStickStartX) * 15.0f));
            setCameraState(1, clampTouchCamera(
                    (event.getY(rightIndex) - rightStickStartY) * 15.0f));
        }
    }

    private void releaseTouchAreaPointer(int pointerId) {
        if (pointerId == leftStickPointerId) {
            resetLeftStick();
        }
        if (pointerId == rightStickPointerId) {
            resetRightTouch();
        }
    }

    private void resetLeftStick() {
        leftStickPointerId = MotionEvent.INVALID_POINTER_ID;
        setAxis(ControllerButtons.AXIS_LX, (short) 0);
        setAxis(ControllerButtons.AXIS_LY, (short) 0);
        leftJoystick.setVisibility(View.INVISIBLE);
    }

    private void resetRightTouch() {
        rightStickPointerId = MotionEvent.INVALID_POINTER_ID;
        setAxis(ControllerButtons.AXIS_RX, (short) 0);
        setAxis(ControllerButtons.AXIS_RY, (short) 0);
    }

    private void setupLookAround(FrameLayout rightScreenArea) {
        rightScreenArea.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View v, MotionEvent event) {
                if (!TouchAreaEnabled) {
                    return false;
                }

                switch (event.getActionMasked()) {
                    case MotionEvent.ACTION_DOWN:
                    case MotionEvent.ACTION_POINTER_DOWN: {
                        if (rightStickPointerId == MotionEvent.INVALID_POINTER_ID) {
                            int pointerIndex = event.getActionIndex();
                            rightStickPointerId = event.getPointerId(pointerIndex);
                            rightStickStartX = event.getX(pointerIndex);
                            rightStickStartY = event.getY(pointerIndex);
                        }
                        return true;
                    }

                    case MotionEvent.ACTION_MOVE: {
                        int pointerIndex = event.findPointerIndex(rightStickPointerId);
                        if (pointerIndex >= 0) {
                            // Displacement from the initial contact behaves like a
                            // physical stick held away from centre until released.
                            float deltaX = event.getX(pointerIndex) - rightStickStartX;
                            float deltaY = event.getY(pointerIndex) - rightStickStartY;
                            float maxRadius = dpToPixels(51);
                            float distance = (float) Math.sqrt(deltaX * deltaX + deltaY * deltaY);
                            if (distance > maxRadius && distance > 0.0f) {
                                float scale = maxRadius / distance;
                                deltaX *= scale;
                                deltaY *= scale;
                            }

                            // Feed the virtual controller's real right-stick axes.
                            // This gives touch the exact same camera mapping, dead
                            // zone, sensitivity, and inversion path as hardware.
                            setAxis(ControllerButtons.AXIS_RX,
                                    (short) (deltaX / maxRadius * Short.MAX_VALUE));
                            setAxis(ControllerButtons.AXIS_RY,
                                    (short) (deltaY / maxRadius * Short.MAX_VALUE));
                        }
                        return true;
                    }

                    case MotionEvent.ACTION_POINTER_UP:
                    case MotionEvent.ACTION_UP:
                        if (event.getPointerId(event.getActionIndex()) == rightStickPointerId) {
                            resetRightTouch();
                        }
                        return true;
                    case MotionEvent.ACTION_CANCEL:
                        resetRightTouch();
                        return true;
                    default:
                        return true;
                }
            }
        });
    }

    private static float clampTouchCamera(float value) {
        // 2Ship multiplies this value by 10, matching the physical N64
        // right stick's approximate -85..85 range.
        return Math.max(-85.0f, Math.min(85.0f, value));
    }





    // Function to set joystick movement with reset to center when not touched
    private void setupJoystick(FrameLayout joystickLayout, ImageView joystickKnob, boolean isLeft) {
        joystickLayout.post(() -> {
            // Calculate the joystick center once, before any events
            final float joystickCenterX = joystickLayout.getWidth() / 2f;
            final float joystickCenterY = joystickLayout.getHeight() / 2f;

            joystickLayout.setOnTouchListener(new View.OnTouchListener() {
                @Override
                public boolean onTouch(View v, MotionEvent event) {
                    switch (event.getAction()) {
                        case MotionEvent.ACTION_DOWN:
                        case MotionEvent.ACTION_MOVE:
                            // Calculate the joystick movement and move the knob
                            float deltaX = event.getX() - joystickCenterX;
                            float deltaY = event.getY() - joystickCenterY;

                            // Clamp the joystick movement to prevent it from going outside the area
                            float maxRadius = joystickLayout.getWidth() / 2f - joystickKnob.getWidth() / 2f;
                            float distance = (float) Math.sqrt(deltaX * deltaX + deltaY * deltaY);
                            if (distance > maxRadius) {
                                float scale = maxRadius / distance;
                                deltaX *= scale;
                                deltaY *= scale;
                            }

                            joystickKnob.setX(joystickCenterX + deltaX - joystickKnob.getWidth() / 2f);
                            joystickKnob.setY(joystickCenterY + deltaY - joystickKnob.getHeight() / 2f);

                            // Send joystick values to native C code
                            short x = (short) (deltaX / maxRadius * Short.MAX_VALUE);
                            short y = (short) (deltaY / maxRadius * Short.MAX_VALUE);

                            // Send X-axis and Y-axis values
                            setAxis(isLeft ? ControllerButtons.AXIS_LX : ControllerButtons.AXIS_RX, x); // X-axis
                            setAxis(isLeft ? ControllerButtons.AXIS_LY : ControllerButtons.AXIS_RY, y); // Y-axis
                            break;

                        case MotionEvent.ACTION_UP:
                        case MotionEvent.ACTION_CANCEL:
                            // Reset joystick knob to the center position (ensure it's placed correctly)
                            joystickKnob.setX(joystickCenterX - joystickKnob.getWidth() / 2f);
                            joystickKnob.setY(joystickCenterY - joystickKnob.getHeight() / 2f);

                            // Reset joystick values to 0 when released or canceled
                            setAxis(isLeft ? ControllerButtons.AXIS_LX : ControllerButtons.AXIS_RX, (short) 0); // X-axis
                            setAxis(isLeft ? ControllerButtons.AXIS_LY : ControllerButtons.AXIS_RY, (short) 0); // Y-axis
                            break;
                    }
                    return true;
                }
            });
        });



}



}
