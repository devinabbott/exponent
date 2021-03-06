// Copyright 2015-present 650 Industries. All rights reserved.

package host.exp.exponent;

import android.app.Activity;
import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Debug;
import android.os.Handler;
import android.support.v4.content.ContextCompat;

import javax.inject.Inject;

import com.facebook.soloader.SoLoader;

import host.exp.exponent.analytics.Analytics;
import host.exp.exponent.exceptions.ExceptionUtils;
import host.exp.exponent.kernel.Kernel;

// This activity is transparent. It uses android:style/Theme.Translucent.NoTitleBar.
// Calls finish() once it is done processing Intent.
public class LauncherActivity extends Activity {

  public static final String MANIFEST_URL_KEY = "manifest_url";
  public static final String NOTIFICATION_KEY = "notification";
  public static final String DEV_FLAG = "dev_flag";

  @Inject
  Kernel mKernel;

  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);

    if (BuildConfig.DEBUG) {
      if (Constants.WAIT_FOR_DEBUGGER) {
        Debug.waitForDebugger();
      }

      // Need WRITE_EXTERNAL_STORAGE for method tracing
      if (Constants.DEBUG_METHOD_TRACING) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
          if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{android.Manifest.permission.WRITE_EXTERNAL_STORAGE}, 123);
          }
        }
      }
    }

    if (Constants.DEBUG_COLD_START_METHOD_TRACING) {
      Debug.startMethodTracing("coldStart");
    }

    Analytics.markEvent(Analytics.TimedEvent.LAUNCHER_ACTIVITY_STARTED);

    SoLoader.init(getApplicationContext(), false);

    ((ExponentApplication) getApplication()).getAppComponent().inject(this);

    mKernel.setActivityContext(this);

    // Add exception handler. This is used by the entire process, so only need to add it here.
    Thread.setDefaultUncaughtExceptionHandler(new ExponentUncaughtExceptionHandler(getApplicationContext()));

    handleIntent(getIntent());

    // Start a service to keep our process awake. This isn't necessary most of the time, but
    // if the user has "Don't keep activities" on it's possible for the process to exit in between
    // finishing this activity and starting the BaseExperienceActivity.
    startService(ExponentIntentService.getActionStayAwake(getApplicationContext()));

    // Delay to prevent race condition where finish() is called before service starts.
    new Handler(getMainLooper()).postDelayed(new Runnable() {
      @Override
      public void run() {
        try {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            // Crash with NoSuchFieldException instead of hard crashing at task.getTaskInfo().numActivities
            ActivityManager.RecentTaskInfo.class.getDeclaredField("numActivities");

            for (ActivityManager.AppTask task : mKernel.getTasks()) {
              if (task.getTaskInfo().id == getTaskId()) {
                if (task.getTaskInfo().numActivities == 1) {
                  finishAndRemoveTask();
                  return;
                } else {
                  break;
                }
              }
            }
          }
        } catch (Exception e) {
          // just go straight to finish()
        }

        finish();
      }
    }, 100);
  }

  @Override
  public void onNewIntent(Intent intent) {
    super.onNewIntent(intent);

    // We shouldn't ever get here, since we call finish() in onCreate. Just want to be safe
    // since this Activity is singleTask and there might be some edge case where this is called.
    handleIntent(intent);
  }

  private void handleIntent(Intent intent) {
    Bundle bundle = intent.getExtras();
    mKernel.setActivityContext(this);

    if (bundle != null) {
      if (bundle.getBoolean(DEV_FLAG)) {
        openDevActivity();
        return;
      }

      String notification = bundle.getString(NOTIFICATION_KEY);
      String manifestUrl = bundle.getString(MANIFEST_URL_KEY);
      if (manifestUrl != null) {
        mKernel.openExperience(new Kernel.ExperienceOptions(manifestUrl, notification));
        return;
      }
    }

    Uri uri = intent.getData();
    if (uri != null) {
      if (Constants.INITIAL_URL == null) {
        // We got an "exp://" link
        mKernel.openExperience(new Kernel.ExperienceOptions(intent.getData().toString(), null));
        return;
      } else {
        // We got a custom scheme link
        // TODO: we still might want to parse this if we're running a different experience inside a
        // shell app. For example, we are running Brighten in the List shell and go to Twitter login.
        // We might want to set the return uri to thelistapp://exp.host/@brighten/brighten+deeplink
        // But we also can't break thelistapp:// deep links that look like thelistapp://l/listid
        mKernel.openExperience(new Kernel.ExperienceOptions(Constants.INITIAL_URL, null));
        return;
      }
    }

    String defaultUrl = Constants.INITIAL_URL == null ? Kernel.HOME_MANIFEST_URL : Constants.INITIAL_URL;
    mKernel.openExperience(new Kernel.ExperienceOptions(defaultUrl, null));
  }

  // Handle this here since we want the dev activity to be as separate from the kernel as possible.
  private void openDevActivity() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
      ActivityManager manager = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
      for (ActivityManager.AppTask task : manager.getAppTasks()) {
        Intent baseIntent = task.getTaskInfo().baseIntent;

        if (ExponentDevActivity.class.getName().equals(baseIntent.getComponent().getClassName())) {
          task.moveToFront();
          return;
        }
      }
    }

    Intent intent = new Intent(this, ExponentDevActivity.class);
    Kernel.addIntentDocumentFlags(intent);
    startActivity(intent);
  }
}
