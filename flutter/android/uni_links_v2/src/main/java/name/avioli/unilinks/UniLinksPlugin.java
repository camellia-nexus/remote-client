package name.avioli.unilinks;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/** Android v2 embedding implementation for the pinned uni_links dependency. */
public class UniLinksPlugin
        implements FlutterPlugin,
                MethodChannel.MethodCallHandler,
                EventChannel.StreamHandler,
                ActivityAware,
                PluginRegistry.NewIntentListener {

    private static final String MESSAGES_CHANNEL = "uni_links/messages";
    private static final String EVENTS_CHANNEL = "uni_links/events";

    private MethodChannel methodChannel;
    private EventChannel eventChannel;
    private ActivityPluginBinding activityPluginBinding;

    private BroadcastReceiver changeReceiver;
    private String initialLink;
    private String latestLink;
    private Context context;
    private boolean initialIntent = true;

    private void handleIntent(Context context, Intent intent) {
        String action = intent.getAction();
        String dataString = intent.getDataString();

        if (Intent.ACTION_VIEW.equals(action)) {
            if (initialIntent) {
                initialLink = dataString;
                initialIntent = false;
            }
            latestLink = dataString;
            if (changeReceiver != null) {
                changeReceiver.onReceive(context, intent);
            }
        }
    }

    @NonNull
    private BroadcastReceiver createChangeReceiver(final EventChannel.EventSink events) {
        return new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                String dataString = intent.getDataString();

                if (dataString == null) {
                    events.error("UNAVAILABLE", "Link unavailable", null);
                } else {
                    events.success(dataString);
                }
            }
        };
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        register(binding.getBinaryMessenger());
    }

    private void register(BinaryMessenger messenger) {
        methodChannel = new MethodChannel(messenger, MESSAGES_CHANNEL);
        methodChannel.setMethodCallHandler(this);

        eventChannel = new EventChannel(messenger, EVENTS_CHANNEL);
        eventChannel.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (methodChannel != null) {
            methodChannel.setMethodCallHandler(null);
            methodChannel = null;
        }
        if (eventChannel != null) {
            eventChannel.setStreamHandler(null);
            eventChannel = null;
        }
        context = null;
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        changeReceiver = createChangeReceiver(events);
    }

    @Override
    public void onCancel(Object arguments) {
        changeReceiver = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        if (call.method.equals("getInitialLink")) {
            result.success(initialLink);
        } else if (call.method.equals("getLatestLink")) {
            result.success(latestLink);
        } else {
            result.notImplemented();
        }
    }

    @Override
    public boolean onNewIntent(@NonNull Intent intent) {
        handleIntent(context, intent);
        return false;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activityPluginBinding = binding;
        binding.addOnNewIntentListener(this);
        handleIntent(context, binding.getActivity().getIntent());
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        if (activityPluginBinding != null) {
            activityPluginBinding.removeOnNewIntentListener(this);
            activityPluginBinding = null;
        }
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activityPluginBinding != null) {
            activityPluginBinding.removeOnNewIntentListener(this);
            activityPluginBinding = null;
        }
    }
}
