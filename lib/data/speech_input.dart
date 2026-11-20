import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart';

/// 语音识别的密封三态结果（与 parsePhrase 同风格，供 UI 分支与测试断言）。
///
/// 设计约束（见 V2_VOICE_CHANGELOG.md）：
///  * 不接第三方 ASR 云服务，仅用系统语音识别；
///  * [SpeechText.text] 是识别原文，未经 trim/lower/任何预处理；
///  * 三态让"语音不可用"与"没听清"两种提示互相独立。
sealed class SpeechResult {
  const SpeechResult();
}

/// 识别成功，[text] 为系统返回的原文（可能含空格/全角，交由后续 parsePhrase 归一化）。
class SpeechText extends SpeechResult {
  const SpeechText(this.text);
  final String text;
}

/// 设备无系统语音识别能力，或未授予麦克风权限。
class SpeechUnavailable extends SpeechResult {
  const SpeechUnavailable();
}

/// 已开始听，但没识别出文字，或用户主动取消。
class SpeechNoResult extends SpeechResult {
  const SpeechNoResult();
}

/// 语音输入抽象：UI 只依赖它，生产注入 [PluginSpeechInput]，测试注入假实现。
abstract class SpeechInput {
  /// 启动一次识别并等待最终结果。
  Future<SpeechResult> listen();

  /// 取消/停止当前识别（页面退出或再次点击话筒时调用）。
  Future<void> cancel();

  /// 是否正在听（按钮状态用）。
  bool get isListening;
}

/// 生产实现：基于 speech_to_text 插件（底层为手机系统语音识别引擎）。
///
/// 懒创建 + 懒初始化：插件实例与 initialize() 都只在首次 listen() 时发生，
/// 确保 widget 测试若不点话筒按钮，绝不触碰平台通道。
class PluginSpeechInput implements SpeechInput {
  PluginSpeechInput({SpeechToText? plugin, this.localeId = 'zh_CN'})
      : _plugin = plugin;

  final SpeechToText? _plugin;
  final String localeId;

  SpeechToText? _resolved;
  bool _initialized = false;
  bool _initOk = false;
  bool _listening = false;
  Completer<SpeechResult>? _completer;

  @override
  bool get isListening => _listening;

  SpeechToText get _speech => _resolved ??= _plugin ?? SpeechToText();

  Future<bool> _ensureInitialized() async {
    if (_initialized) return _initOk;
    _initialized = true;
    _initOk = await _speech.initialize(
      onError: (_) => _finishWith(const SpeechUnavailable()),
      onStatus: (status) {
        // 系统报 done/notListening 但还没拿到最终结果时，按无结果收口，
        // 避免 completer 悬挂。已有最终结果时 _completer 已置空，不会再触发。
        if (status == 'done' || status == 'notListening') {
          _finishWith(const SpeechNoResult());
        }
      },
    );
    return _initOk;
  }

  void _finishWith(SpeechResult result) {
    final c = _completer;
    if (c != null && !c.isCompleted) {
      c.complete(result);
      _completer = null;
      _listening = false;
    }
  }

  @override
  Future<SpeechResult> listen() async {
    final ok = await _ensureInitialized();
    if (!ok) return const SpeechUnavailable();

    // 若上一次还在听，先取消，避免重复会话。
    if (_listening) await cancel();

    final completer = Completer<SpeechResult>();
    _completer = completer;
    _listening = true;

    await _speech.listen(
      onResult: (result) {
        if (!result.finalResult) return;
        final text = result.recognizedWords;
        if (text.isEmpty) {
          _finishWith(const SpeechNoResult());
        } else {
          _finishWith(SpeechText(text));
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: false,
        cancelOnError: true,
        listenMode: ListenMode.confirmation,
        localeId: localeId,
      ),
    );

    return completer.future;
  }

  @override
  Future<void> cancel() async {
    if (!_listening) return;
    _listening = false;
    _finishWith(const SpeechNoResult());
    await _speech.cancel();
  }
}
