import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/android_update_service.dart';
import '../theme/app_theme.dart';

enum _UpdateGateState { checking, current, required, checkFailed }

class AndroidUpdateGate extends StatefulWidget {
  final Widget child;
  final bool forceCheckForTesting;
  final Future<AndroidUpdateCheckResult> Function()? updateChecker;
  final Future<bool> Function()? storeLauncher;

  const AndroidUpdateGate({
    super.key,
    required this.child,
    this.forceCheckForTesting = false,
    this.updateChecker,
    this.storeLauncher,
  });

  @override
  State<AndroidUpdateGate> createState() => _AndroidUpdateGateState();
}

class _AndroidUpdateGateState extends State<AndroidUpdateGate>
    with WidgetsBindingObserver {
  static const Duration _checkTimeout = Duration(seconds: 15);

  _UpdateGateState _state = _UpdateGateState.checking;
  String? _installedVersion;
  int? _availableVersionCode;
  String? _storeError;
  bool _checkInProgress = false;
  bool _openedStore = false;

  bool get _shouldCheckForUpdates {
    if (widget.forceCheckForTesting) {
      return true;
    }
    return !kDebugMode &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadInstalledVersion());
    unawaited(_checkForUpdate());
  }

  Future<void> _loadInstalledVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _installedVersion = '${info.version}+${info.buildNumber}';
        });
      }
    } catch (_) {
      // Version text is informational; it must not weaken the update gate.
    }
  }

  Future<void> _checkForUpdate() async {
    if (!_shouldCheckForUpdates) {
      if (mounted) {
        setState(() => _state = _UpdateGateState.current);
      }
      return;
    }
    if (_checkInProgress) {
      return;
    }

    _checkInProgress = true;
    if (mounted) {
      setState(() {
        _state = _UpdateGateState.checking;
        _storeError = null;
      });
    }

    try {
      final checker =
          widget.updateChecker ?? AndroidUpdateService.checkForUpdate;
      final result = await checker().timeout(_checkTimeout);
      if (!mounted) {
        return;
      }

      setState(() {
        _availableVersionCode = result.availableVersionCode;
        _state = result.updateRequired
            ? _UpdateGateState.required
            : _UpdateGateState.current;
      });
    } catch (error) {
      debugPrint('Required app update check failed: $error');
      if (mounted) {
        setState(() => _state = _UpdateGateState.checkFailed);
      }
    } finally {
      _checkInProgress = false;
    }
  }

  Future<void> _openPlayStore() async {
    if (_openedStore) {
      return;
    }

    setState(() {
      _openedStore = true;
      _storeError = null;
    });

    final launcher = widget.storeLauncher ?? AndroidUpdateService.openPlayStore;
    final opened = await launcher();
    if (!mounted) {
      return;
    }
    if (!opened) {
      setState(() {
        _openedStore = false;
        _storeError = 'Could not open Google Play. Please try again.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _state == _UpdateGateState.required &&
        _openedStore) {
      _openedStore = false;
      unawaited(_checkForUpdate());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _UpdateGateState.current) {
      return widget.child;
    }

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: _buildGateContent(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGateContent() {
    final isChecking = _state == _UpdateGateState.checking;
    final checkFailed = _state == _UpdateGateState.checkFailed;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 86,
          height: 86,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryNavy.withValues(alpha: 0.14),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Image.asset('assets/logo.png', fit: BoxFit.contain),
        ),
        const SizedBox(height: 32),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: (checkFailed ? AppColors.accentRed : AppColors.primaryNavy)
                .withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: isChecking
              ? const Padding(
                  padding: EdgeInsets.all(22),
                  child: CircularProgressIndicator(
                    color: AppColors.primaryNavy,
                    strokeWidth: 3,
                  ),
                )
              : Icon(
                  checkFailed
                      ? Icons.wifi_off_rounded
                      : Icons.system_update_rounded,
                  size: 36,
                  color: checkFailed
                      ? AppColors.accentRed
                      : AppColors.primaryNavy,
                ),
        ),
        const SizedBox(height: 24),
        Text(
          isChecking
              ? 'Checking for updates'
              : checkFailed
              ? 'Unable to check for updates'
              : 'Update required',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 23,
            fontWeight: FontWeight.w700,
            color: AppColors.primaryNavy,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          isChecking
              ? 'Please wait while we check Google Play for the latest version.'
              : checkFailed
              ? 'Connect to the internet and try again. The app must verify that it is up to date before continuing.'
              : 'A newer version of Scholars Academy is available. Update from Google Play to continue using the app.',
          textAlign: TextAlign.center,
          style: GoogleFonts.poppins(
            fontSize: 14,
            height: 1.55,
            color: AppColors.textSecondary,
          ),
        ),
        if (!isChecking && _installedVersion != null) ...[
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.divider),
            ),
            child: Text(
              _availableVersionCode == null
                  ? 'Installed version: $_installedVersion'
                  : 'Installed: $_installedVersion  |  New build: $_availableVersionCode',
              style: GoogleFonts.poppins(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
        if (_storeError != null) ...[
          const SizedBox(height: 16),
          Text(
            _storeError!,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.accentRed,
            ),
          ),
        ],
        if (!isChecking) ...[
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: checkFailed
                  ? _checkForUpdate
                  : (_openedStore ? null : _openPlayStore),
              icon: Icon(
                checkFailed ? Icons.refresh_rounded : Icons.shop_rounded,
              ),
              label: Text(
                checkFailed
                    ? 'Try Again'
                    : (_openedStore ? 'Opening Google Play...' : 'Update Now'),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
