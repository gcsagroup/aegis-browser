package app.gcsa.aegis.qa.driver;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.KeyguardManager;
import android.app.UiAutomation;
import android.content.Context;
import android.content.Intent;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.os.PowerManager;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Base64;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.TimeoutException;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.json.JSONArray;
import org.json.JSONObject;

/** 一次性真机验收驱动，不是产品 Agent，也不能证明模型任务完成。 */
public final class Driver extends Instrumentation {
  private static final String BROWSER = "app.gcsa.aegis";
  private static final String HELPER = "app.gcsa.aegis.qa.driver";
  private static final String PROFILE = "/data/user/0/app\\.gcsa\\.aegis/aegis-test-user-data-[a-z0-9-]+";
  private UiAutomation automation;
  private JSONObject request;
  private boolean coverageRequested;

  @Override public void onCreate(Bundle arguments) {
    super.onCreate(arguments);
    try {
      String coverage = arguments.getString("jacoco_coverage", "");
      check(coverage.isEmpty() || coverage.equals("true"), "coverage 参数无效");
      coverageRequested = coverage.equals("true");
      String encoded = arguments.getString("request_base64", "");
      check(encoded.length() <= 24000, "验收参数过长");
      request = new JSONObject(new String(Base64.decode(encoded, Base64.DEFAULT), StandardCharsets.UTF_8));
      check(!coverageRequested || request.optString("action").equals("self-test"), "coverage 只允许工具自测");
    } catch (Exception error) {
      finishResult(null, "验收参数无效");
      return;
    }
    start();
  }

  @Override public void onStart() {
    super.onStart();
    try {
      unlocked();
      automation = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
      check(automation != null, "无法连接一次性 UI 验收通道");
      String action = request.getString("action");
      if (action.equals("self-test")) {
        finishResult(selfTest(), null);
      } else {
        check(action.equals("snapshot") || action.equals("click") || action.equals("set-text"), "不支持的操作");
        browserGuard();
        JSONObject before = snapshot(BROWSER);
        if (!action.equals("snapshot")) {
          perform(BROWSER, before, request.getString("snapshotSha256"),
              request.getString("node"), action, request.optString("text", ""));
          browserGuard();
        }
        JSONObject result = action.equals("snapshot") ? before : snapshot(BROWSER);
        result.put("actionAccepted", !action.equals("snapshot"));
        result.put("action", action);
        finishResult(result, null);
      }
    } catch (Exception error) {
      // 只返回本工具定义的边界错误，不回传系统异常里的资料或界面内容。
      finishResult(null, error instanceof GuardFailure ? error.getMessage() : "UI 验收异常：" + error.getClass().getSimpleName());
    }
  }

  private void finishResult(JSONObject result, String error) {
    try {
      byte[] executionData = null;
      String finalError = error;
      if (coverageRequested) {
        try {
          executionData = coverageExecutionData();
        } catch (Exception coverageError) {
          if (finalError == null) finalError = "coverage 导出失败：" + coverageError.getClass().getSimpleName();
        }
      }
      if (result == null) result = new JSONObject();
      result.put("ok", finalError == null);
      result.put("runtimeTested", false);
      result.put("releaseEligible", false);
      result.put("qualification", "ui-driver-only");
      if (finalError != null) result.put("error", finalError);
      Bundle output = new Bundle();
      output.putString("aegis_result", Base64.encodeToString(result.toString().getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP));
      if (executionData != null) {
        output.putString("aegis_coverage", Base64.encodeToString(executionData, Base64.NO_WRAP));
      }
      finish(finalError == null ? Activity.RESULT_OK : Activity.RESULT_CANCELED, output);
    } catch (Exception ignored) {
      finish(Activity.RESULT_CANCELED, new Bundle());
    }
  }

  private static byte[] coverageExecutionData() throws Exception {
    Class<?> runtime = Class.forName("org.jacoco.agent.rt.RT");
    Object agent = runtime.getMethod("getAgent").invoke(null);
    Class<?> agentInterface = Class.forName("org.jacoco.agent.rt.IAgent");
    byte[] data = (byte[]) agentInterface.getMethod("getExecutionData", boolean.class).invoke(agent, false);
    check(data != null && data.length >= 5 && data.length <= 2 * 1024 * 1024, "coverage 数据大小无效");
    return data;
  }

  private static final class GuardFailure extends Exception {
    GuardFailure(String message) { super(message); }
  }

  private static void check(boolean condition, String message) throws GuardFailure {
    if (!condition) throw new GuardFailure(message);
  }

  private void unlocked() throws Exception {
    Context context = getTargetContext();
    KeyguardManager keyguard = context.getSystemService(KeyguardManager.class);
    PowerManager power = context.getSystemService(PowerManager.class);
    check(keyguard != null && power != null && !keyguard.isKeyguardLocked() && power.isInteractive(),
        "设备锁定或灭屏；不会自动解锁或唤醒");
  }

  private String shell(String command) throws Exception {
    // 调用者只有下方三个固定的只读命令；从不接受外部命令文本。
    try (ParcelFileDescriptor descriptor = automation.executeShellCommand(command);
         FileInputStream input = new FileInputStream(descriptor.getFileDescriptor());
         ByteArrayOutputStream output = new ByteArrayOutputStream()) {
      byte[] buffer = new byte[4096];
      for (int size; (size = input.read(buffer)) != -1;) {
        check(output.size() + size <= 2 * 1024 * 1024, "目标元数据超出读取上限");
        output.write(buffer, 0, size);
      }
      return output.toString("UTF-8");
    }
  }

  private void browserGuard() throws Exception {
    unlocked();
    String profile = request.getString("profile");
    String expectedHash = request.getString("apkSha256");
    check(profile.matches(PROFILE) && expectedHash.matches("[a-f0-9]{64}"), "候选或独立资料参数无效");
    check(shell("am get-current-user").trim().equals("0"), "当前不是指定 Android 用户");
    String apk = getTargetContext().getPackageManager().getApplicationInfo(BROWSER, 0).sourceDir;
    MessageDigest digest = MessageDigest.getInstance("SHA-256");
    try (FileInputStream input = new FileInputStream(apk)) {
      byte[] buffer = new byte[65536];
      for (int size; (size = input.read(buffer)) != -1;) digest.update(buffer, 0, size);
    }
    check(hex(digest.digest()).equals(expectedHash), "运行中的 APK 不属于指定候选");
    String pid = shell("pidof " + BROWSER).trim();
    check(pid.matches("[0-9]+"), "未找到唯一浏览器进程");
    String descriptors = shell("run-as " + BROWSER + " ls -l /proc/" + pid + "/fd");
    Matcher paths = Pattern.compile(" -> (/data/(?:user/0|data)/app\\.gcsa\\.aegis/[^\\r\\n]*?)/(?:Default|Profile [0-9]+)/").matcher(descriptors);
    Set<String> roots = new HashSet<>();
    while (paths.find()) roots.add(paths.group(1).replace("/data/data/", "/data/user/0/"));
    check(roots.size() == 1 && roots.contains(profile), "拒绝默认资料或未经证实的独立 Profile");
    check(shell("pidof " + BROWSER).trim().equals(pid), "浏览器进程已变化，请重新检查");
  }

  private static String hex(byte[] data) {
    StringBuilder output = new StringBuilder();
    for (byte value : data) output.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
    return output.toString();
  }

  private AccessibilityNodeInfo root(String target) throws Exception {
    unlocked();
    AccessibilityNodeInfo root = automation.getRootInActiveWindow();
    check(root != null, "没有活动的无障碍窗口");
    requirePackage(root, target);
    return root;
  }

  private String activeWindowPackage() {
    AccessibilityNodeInfo root = automation.getRootInActiveWindow();
    String value = root == null || root.getPackageName() == null ? "none" : root.getPackageName().toString();
    return value.matches("[A-Za-z0-9_.]{1,200}") ? value : "unknown";
  }

  private static void requirePackage(AccessibilityNodeInfo node, String target) throws Exception {
    check(node != null && target.contentEquals(node.getPackageName() == null ? "" : node.getPackageName()),
        "前台不是指定验收 App；未读取或操作其他应用");
  }

  private static String bounded(CharSequence value) {
    String text = value == null ? "" : value.toString();
    return text.length() <= 2048 ? text : text.substring(0, 2048);
  }

  private void collect(AccessibilityNodeInfo node, String target, String id, int depth, JSONArray nodes) throws Exception {
    check(depth <= 40 && nodes.length() < 600, "界面树超出验收读取上限");
    requirePackage(node, target);
    Rect bounds = new Rect();
    node.getBoundsInScreen(bounds);
    boolean password = node.isPassword();
    JSONObject item = new JSONObject();
    item.put("node", id);
    item.put("role", bounded(node.getClassName()));
    item.put("viewId", bounded(node.getViewIdResourceName()));
    item.put("text", password ? "[密码已隐藏]" : bounded(node.getText()));
    item.put("label", password ? "[密码已隐藏]" : bounded(node.getContentDescription()));
    item.put("visible", node.isVisibleToUser());
    item.put("enabled", node.isEnabled());
    item.put("clickable", node.isClickable());
    item.put("editable", node.isEditable());
    item.put("password", password);
    item.put("bounds", new JSONArray(new int[] {bounds.left, bounds.top, bounds.right, bounds.bottom}));
    nodes.put(item);
    for (int index = 0; index < node.getChildCount(); index++) {
      AccessibilityNodeInfo child = node.getChild(index);
      if (child != null) collect(child, target, id + "." + index, depth + 1, nodes);
    }
  }

  private JSONObject snapshot(String target) throws Exception {
    AccessibilityNodeInfo root = root(target);
    JSONArray nodes = new JSONArray();
    collect(root, target, "0", 0, nodes);
    String text = nodes.toString();
    check(text.length() <= 200000, "界面快照超出验收读取上限");
    JSONObject result = new JSONObject();
    result.put("package", target);
    result.put("windowId", root.getWindowId());
    result.put("nodes", nodes);
    result.put("snapshotSha256", hex(MessageDigest.getInstance("SHA-256")
        .digest((root.getWindowId() + ":" + text).getBytes(StandardCharsets.UTF_8))));
    return result;
  }

  private void perform(String target, JSONObject current, String expected, String id, String action, String text) throws Exception {
    check(current.getString("snapshotSha256").equals(expected), "页面已变化，必须重新观察后再操作");
    check(id.matches("0(?:\\.[0-9]{1,3}){0,40}"), "节点编号无效");
    AccessibilityNodeInfo node = root(target);
    String[] parts = id.split("\\.");
    for (int index = 1; index < parts.length; index++) {
      node = node.getChild(Integer.parseInt(parts[index]));
      requirePackage(node, target);
    }
    check(node.isVisibleToUser() && node.isEnabled() && !node.isPassword(), "节点不可操作，或属于密码框");
    check(snapshot(target).getString("snapshotSha256").equals(expected), "执行前页面已变化");
    boolean accepted;
    if (action.equals("set-text")) {
      check(node.isEditable() && text.length() <= 8192, "目标不是可编辑文本框，或文本过长");
      Bundle arguments = new Bundle();
      arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text);
      accepted = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments);
    } else {
      check(action.equals("click") && node.isClickable(), "目标不支持点击");
      accepted = node.performAction(AccessibilityNodeInfo.ACTION_CLICK);
    }
    check(accepted, "系统未接受此操作；不会自动盲目重试");
    waitForIdleSync();
  }

  private static String find(JSONObject state, String property, Object value) throws Exception {
    JSONArray nodes = state.getJSONArray("nodes");
    String found = null;
    for (int index = 0; index < nodes.length(); index++) {
      JSONObject node = nodes.getJSONObject(index);
      if (node.get(property).equals(value)) {
        check(found == null, "自测节点不唯一");
        found = node.getString("node");
      }
    }
    check(found != null, "自测节点未出现");
    return found;
  }

  private static void passed(JSONArray results, String id) throws Exception {
    JSONObject item = new JSONObject();
    item.put("id", id);
    item.put("passed", true);
    results.put(item);
  }

  private JSONObject selfTest() throws Exception {
    Fixture.resetLifecycle();
    Activity[] fixture = new Activity[1];
    try {
      automation.executeAndWaitForEvent(
          () -> fixture[0] = startActivitySync(
              new Intent(getTargetContext(), Fixture.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)),
          event -> event.getEventType() == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED &&
              HELPER.contentEquals(event.getPackageName()), 5000);
    } catch (TimeoutException error) {
      throw new GuardFailure("自测窗口事件未出现；" + Fixture.lifecycle() + ";activePackage=" + activeWindowPackage());
    }
    check(fixture[0] != null, "自测 Activity 未创建");
    Activity activity = fixture[0];
    try {
      waitForIdleSync();
      JSONArray results = new JSONArray();
      JSONObject initial = null;
      String lastFailure = "尚未观察";
      long deadline = SystemClock.uptimeMillis() + 5000;
      do {
        try { initial = snapshot(HELPER); break; }
        catch (GuardFailure error) {
          lastFailure = error.getMessage();
          SystemClock.sleep(50);
        }
      } while (SystemClock.uptimeMillis() < deadline);
      check(initial != null, "自测界面未就绪；" + Fixture.lifecycle() + ";category=" + lastFailure +
          ";activePackage=" + activeWindowPackage());
      String input = find(initial, "label", "中文目标输入");
      String text = "帮我总结页面内容：电池续航18小时 🔋";
      perform(HELPER, initial, initial.getString("snapshotSha256"), input, "set-text", text);
      JSONObject edited = snapshot(HELPER);
      find(edited, "text", text);
      passed(results, "unicode-input");
      boolean refused = false;
      try { perform(HELPER, edited, initial.getString("snapshotSha256"), input, "set-text", "不应写入"); }
      catch (GuardFailure expected) { refused = true; }
      check(refused, "过期快照没有被拒绝");
      passed(results, "stale-snapshot-rejected");
      refused = false;
      try { requirePackage(root(HELPER), BROWSER); }
      catch (GuardFailure expected) { refused = true; }
      check(refused, "错误应用没有被拒绝");
      passed(results, "wrong-package-rejected");
      refused = false;
      try { perform(HELPER, edited, edited.getString("snapshotSha256"), find(edited, "password", true), "set-text", "不应写入"); }
      catch (GuardFailure expected) { refused = true; }
      check(refused, "密码框写入没有被拒绝");
      passed(results, "password-edit-rejected");
      perform(HELPER, edited, edited.getString("snapshotSha256"), find(edited, "text", "确认中文输入"), "click", "");
      JSONObject finalState = snapshot(HELPER);
      find(finalState, "text", "已收到：" + text);
      passed(results, "click-updates-result");
      check(!finalState.toString().contains("fixture-password"), "密码框内容没有正确隐藏");
      passed(results, "password-value-hidden");
      finalState.put("selfTestCases", results.length());
      finalState.put("selfTestResults", results);
      finalState.put("browserTested", false);
      return finalState;
    } finally {
      runOnMainSync(activity::finish);
    }
  }

  /** 仅验证 Unicode 输入与原生点击；不伪装成产品界面或模型结果。 */
  public static final class Fixture extends Activity {
    private static volatile boolean created;
    private static volatile boolean resumed;
    private static volatile boolean focused;

    private static void resetLifecycle() {
      created = false;
      resumed = false;
      focused = false;
    }

    private static String lifecycle() {
      return "created=" + created + ",resumed=" + resumed + ",focused=" + focused;
    }

    @Override public void onCreate(Bundle saved) {
      super.onCreate(saved);
      created = true;
      getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN);
      LinearLayout layout = new LinearLayout(this);
      layout.setOrientation(LinearLayout.VERTICAL);
      layout.setPadding(24, 48, 24, 24);
      layout.setFocusableInTouchMode(true);
      TextView title = new TextView(this);
      title.setText("Aegis 验收工具自测（不是浏览器）");
      EditText input = new EditText(this);
      input.setContentDescription("中文目标输入");
      input.setSingleLine(false);
      EditText password = new EditText(this);
      password.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
      password.setText("fixture-password");
      Button button = new Button(this);
      button.setText("确认中文输入");
      TextView result = new TextView(this);
      result.setText("等待输入");
      button.setOnClickListener(view -> result.setText("已收到：" + input.getText()));
      layout.addView(title);
      layout.addView(input);
      layout.addView(password);
      layout.addView(button);
      layout.addView(result);
      setContentView(layout);
      layout.requestFocus();
    }

    @Override protected void onResume() {
      super.onResume();
      resumed = true;
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
      super.onWindowFocusChanged(hasFocus);
      focused = hasFocus;
    }
  }
}
