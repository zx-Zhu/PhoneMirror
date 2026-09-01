import com.sun.jdi.ArrayReference;
import com.sun.jdi.BooleanValue;
import com.sun.jdi.ClassType;
import com.sun.jdi.Field;
import com.sun.jdi.Method;
import com.sun.jdi.ObjectReference;
import com.sun.jdi.ReferenceType;
import com.sun.jdi.StringReference;
import com.sun.jdi.ThreadReference;
import com.sun.jdi.Value;
import com.sun.jdi.VirtualMachine;
import com.sun.jdi.connect.AttachingConnector;
import com.sun.jdi.connect.Connector;
import com.sun.jdi.event.Event;
import com.sun.jdi.event.EventSet;
import com.sun.jdi.event.MethodEntryEvent;
import com.sun.jdi.request.EventRequest;
import com.sun.jdi.request.MethodEntryRequest;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * Mutates LocalAbOverrideManager's in-process map through JDWP. This helper
 * deliberately never invokes saveOverride()/persist(), so Android app files
 * are not touched and all changes disappear when the process exits.
 */
public final class RuntimeSettingsBridge {
    private static final String MANAGER =
        "com.dragon.read.pages.debug.ab.abinfo.LocalAbOverrideManager";
    private static final String SS_CONFIG_MANAGER =
        "com.dragon.read.base.ssconfig.SsConfigMgr";
    private static final String LOCAL_EDIT_GATE_KEY = "ab_info_local_edit_v731";
    private final VirtualMachine vm;
    private ThreadReference eventThread;
    private EventSet suspendedEvent;
    private Process triggerProcess;

    private RuntimeSettingsBridge(VirtualMachine vm) {
        this.vm = vm;
    }

    public static void main(String[] args) {
        if (args.length < 7) {
            fail("usage: <host> <port> <adb> <device> <package> <filter|probe|get|set|clear> <key> [value_base64]");
            return;
        }
        VirtualMachine vm = null;
        RuntimeSettingsBridge bridge = null;
        boolean succeeded = false;
        try {
            vm = attach(args[0], args[1]);
            bridge = new RuntimeSettingsBridge(vm);
            if (!"filter".equals(args[5])) {
                bridge.acquireInvokableThread(args[2], args[3], args[4], args[6]);
            }
            String result = bridge.execute(args[5], args[6], args.length > 7 ? args[7] : null);
            System.out.println("{\"success\":true," + result + "}");
            succeeded = true;
        } catch (Throwable error) {
            String message = error.getMessage();
            if (message == null || message.isEmpty()) message = error.getClass().getSimpleName();
            printFailure(message);
        } finally {
            if (bridge != null) bridge.releaseThread();
            if (vm != null) {
                try { vm.dispose(); } catch (Throwable ignored) {}
            }
        }
        if (!succeeded) System.exit(1);
    }

    private String execute(String operation, String keyText, String encodedValue) throws Exception {
        List<ReferenceType> loaded = vm.classesByName(MANAGER);
        if (loaded.isEmpty() || !(loaded.get(0) instanceof ClassType)) {
            throw new IllegalStateException("当前调试包未加载运行时配置管理器");
        }
        ClassType manager = (ClassType) loaded.get(0);
        if (!staticBoolean(manager, "interceptorRegistered")
            || !staticBoolean(manager, "runtimeEnabled")
            || !staticBoolean(manager, "featureEnabled")) {
            throw new IllegalStateException("当前调试包未启用本地配置拦截能力");
        }
        if ("filter".equals(operation)) {
            return filterSupportedKeys(encodedValue);
        }
        ObjectReference overrides = staticObject(manager, "overrideMap");
        StringReference key = vm.mirrorOf(keyText);

        if ("probe".equals(operation)) {
            int size = ((com.sun.jdi.IntegerValue) invoke(
                overrides, "size", "()I", Collections.emptyList()
            )).value();
            return "\"message\":\"runtime bridge ready\",\"size\":" + size;
        }
        if ("get".equals(operation)) {
            Value value = invoke(
                overrides, "get", "(Ljava/lang/Object;)Ljava/lang/Object;", List.of(key)
            );
            String text = value instanceof StringReference ? ((StringReference) value).value() : null;
            return "\"key\":\"" + json(keyText) + "\",\"value_base64\":"
                + (text == null ? "null" : "\"" + encode(text) + "\"");
        }
        if ("clear".equals(operation)) {
            requireSupportedKey(keyText);
            invoke(overrides, "remove", "(Ljava/lang/Object;)Ljava/lang/Object;", List.of(key));
            Value remaining = invoke(
                overrides, "get", "(Ljava/lang/Object;)Ljava/lang/Object;", List.of(key)
            );
            if (remaining != null) {
                throw new IllegalStateException("运行时覆盖清除校验失败");
            }
            return "\"message\":\"runtime override cleared\",\"key\":\"" + json(keyText) + "\"";
        }
        if (!"set".equals(operation) || encodedValue == null) {
            throw new IllegalArgumentException("未知运行时操作");
        }
        requireSupportedKey(keyText);
        String text = new String(Base64.getDecoder().decode(encodedValue), StandardCharsets.UTF_8);
        String previous = putAndVerify(overrides, keyText, text);
        return "\"message\":\"runtime override applied\",\"key\":\""
            + json(keyText) + "\",\"previous_value_base64\":"
            + (previous == null ? "null" : "\"" + encode(previous) + "\"");
    }

    private String filterSupportedKeys(String encodedValue) throws Exception {
        if (encodedValue == null) {
            throw new IllegalArgumentException("缺少 Settings key 列表");
        }
        List<ReferenceType> loaded = vm.classesByName(SS_CONFIG_MANAGER);
        if (loaded.isEmpty() || !(loaded.get(0) instanceof ClassType)) {
            throw new IllegalStateException("当前调试包未加载 SsConfigMgr");
        }
        ClassType manager = (ClassType) loaded.get(0);
        Set<String> registeredKeys = registeredKeys(manager);
        String payload = new String(
            Base64.getDecoder().decode(encodedValue), StandardCharsets.UTF_8
        );
        String[] candidates = payload.isEmpty() ? new String[0] : payload.split("\n");
        byte[] bitmap = new byte[(candidates.length + 7) / 8];
        int supportedCount = 0;
        for (int index = 0; index < candidates.length; index++) {
            String line = candidates[index];
            if (line.isEmpty()) continue;
            String key = new String(
                Base64.getDecoder().decode(line), StandardCharsets.UTF_8
            );
            if (key.isEmpty() || LOCAL_EDIT_GATE_KEY.equals(key)) continue;
            if (registeredKeys.contains(key)) {
                bitmap[index / 8] |= (byte) (1 << (index % 8));
                supportedCount++;
            }
        }
        return "\"message\":\"runtime Settings filtered\",\"candidate_count\":"
            + candidates.length + ",\"supported_count\":" + supportedCount
            + ",\"supported_bitmap_base64\":\""
            + Base64.getEncoder().encodeToString(bitmap) + "\"";
    }

    private Set<String> registeredKeys(ClassType manager) throws Exception {
        ObjectReference models = staticObject(manager, "abModelMap");
        Set<String> result = new HashSet<>();
        Field tableField = models.referenceType().fieldByName("table");
        Value tableValue = tableField == null ? null : models.getValue(tableField);
        if (!(tableValue instanceof ArrayReference)) {
            throw new IllegalStateException("SsConfigMgr 注册表格式无效");
        }
        Set<Long> visited = new HashSet<>();
        for (Value bucket : ((ArrayReference) tableValue).getValues()) {
            if (bucket instanceof ObjectReference) {
                collectMapNode((ObjectReference) bucket, result, visited);
            }
        }
        return result;
    }

    private void collectMapNode(
        ObjectReference node, Set<String> keys, Set<Long> visited
    ) {
        if (!visited.add(node.uniqueID())) return;
        Field keyField = node.referenceType().fieldByName("key");
        Value keyValue = keyField == null ? null : node.getValue(keyField);
        if (keyValue instanceof StringReference) {
            keys.add(((StringReference) keyValue).value());
        }
        for (String childName : List.of("next", "first")) {
            Field childField = node.referenceType().fieldByName(childName);
            Value child = childField == null ? null : node.getValue(childField);
            if (child instanceof ObjectReference) {
                collectMapNode((ObjectReference) child, keys, visited);
            }
        }
        Field nextTableField = node.referenceType().fieldByName("nextTable");
        Value nextTable = nextTableField == null ? null : node.getValue(nextTableField);
        if (nextTable instanceof ArrayReference) {
            for (Value bucket : ((ArrayReference) nextTable).getValues()) {
                if (bucket instanceof ObjectReference) {
                    collectMapNode((ObjectReference) bucket, keys, visited);
                }
            }
        }
    }

    private void requireSupportedKey(String key) throws Exception {
        if (key.isEmpty() || LOCAL_EDIT_GATE_KEY.equals(key)) {
            throw new IllegalArgumentException("该配置不能运行时覆盖");
        }
        List<ReferenceType> loaded = vm.classesByName(SS_CONFIG_MANAGER);
        if (loaded.isEmpty() || !(loaded.get(0) instanceof ClassType)
            || !registeredKeys((ClassType) loaded.get(0)).contains(key)) {
            throw new IllegalArgumentException("该配置未注册到 SsConfigMgr");
        }
    }

    private String putAndVerify(
        ObjectReference overrides, String keyText, String text
    ) throws Exception {
        StringReference key = vm.mirrorOf(keyText);
        StringReference value = vm.mirrorOf(text);
        Value previous = invoke(
            overrides, "put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
            List.of(key, value)
        );
        Value verified = invoke(
            overrides, "get", "(Ljava/lang/Object;)Ljava/lang/Object;", List.of(key)
        );
        if (!(verified instanceof StringReference)
            || !text.equals(((StringReference) verified).value())) {
            throw new IllegalStateException("运行时值校验失败");
        }
        return previous instanceof StringReference ? ((StringReference) previous).value() : null;
    }

    private void acquireInvokableThread(
        String adb, String device, String packageName, String key
    ) throws Exception {
        ThreadReference mainThread = vm.allThreads().stream()
            .filter(thread -> "main".equals(thread.name()))
            .findFirst().orElseThrow(() -> new IllegalStateException("未找到 App 主线程"));
        MethodEntryRequest request = vm.eventRequestManager().createMethodEntryRequest();
        request.addThreadFilter(mainThread);
        request.addCountFilter(1);
        request.setSuspendPolicy(EventRequest.SUSPEND_ALL);
        request.enable();
        vm.resume();

        triggerProcess = new ProcessBuilder(
            adb, "-s", device, "shell", "input", "keyevent", "KEYCODE_UNKNOWN"
        ).redirectErrorStream(true).start();
        EventSet events = vm.eventQueue().remove(10_000);
        request.disable();
        if (events == null) {
            triggerProcess.destroyForcibly();
            throw new IllegalStateException("等待 App 运行线程超时，请保持 App 在前台");
        }
        for (Event event : events) {
            if (event instanceof MethodEntryEvent) {
                eventThread = ((MethodEntryEvent) event).thread();
                suspendedEvent = events;
                return;
            }
        }
        events.resume();
        triggerProcess.destroyForcibly();
        throw new IllegalStateException("未获得可调用的 App 线程");
    }

    private void releaseThread() {
        if (suspendedEvent != null) {
            try { suspendedEvent.resume(); } catch (Throwable ignored) {}
            suspendedEvent = null;
        }
        if (triggerProcess != null && triggerProcess.isAlive()) {
            triggerProcess.destroyForcibly();
        }
    }

    private ObjectReference staticObject(ClassType type, String name) {
        Field field = type.fieldByName(name);
        Value value = field == null ? null : type.getValue(field);
        if (!(value instanceof ObjectReference)) {
            throw new IllegalStateException("缺少运行时字段：" + name);
        }
        return (ObjectReference) value;
    }

    private boolean staticBoolean(ClassType type, String name) {
        Field field = type.fieldByName(name);
        Value value = field == null ? null : type.getValue(field);
        return value instanceof BooleanValue && ((BooleanValue) value).value();
    }

    private Value invoke(
        ObjectReference target, String name, String signature, List<? extends Value> arguments
    ) throws Exception {
        Method method = target.referenceType().allMethods().stream()
            .filter(item -> item.name().equals(name) && item.signature().equals(signature))
            .findFirst().orElseThrow(() -> new NoSuchMethodException(name + signature));
        return target.invokeMethod(
            eventThread, method, arguments, ObjectReference.INVOKE_SINGLE_THREADED
        );
    }

    private static VirtualMachine attach(String host, String port) throws Exception {
        AttachingConnector connector = com.sun.jdi.Bootstrap.virtualMachineManager()
            .attachingConnectors().stream()
            .filter(item -> "com.sun.jdi.SocketAttach".equals(item.name()))
            .findFirst().orElseThrow(() -> new IllegalStateException("JDI SocketAttach 不可用"));
        Map<String, Connector.Argument> arguments = connector.defaultArguments();
        arguments.get("hostname").setValue(host);
        arguments.get("port").setValue(port);
        arguments.get("timeout").setValue("10000");
        return connector.attach(arguments);
    }

    private static String encode(String input) {
        return Base64.getEncoder().encodeToString(input.getBytes(StandardCharsets.UTF_8));
    }

    private static String json(String input) {
        return input.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    private static void fail(String message) {
        printFailure(message);
        System.exit(1);
    }

    private static void printFailure(String message) {
        System.out.println("{\"success\":false,\"message\":\"" + json(message) + "\"}");
    }
}
