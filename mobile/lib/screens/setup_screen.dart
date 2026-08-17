import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../store.dart';
import '../widgets/common.dart';

/// First run, and the place to come back to when the address changes.
/// Two steps, both of which have to pass before try-on can work.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key, required this.store});

  final EasyBuyStore store;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final TextEditingController _urlController =
      TextEditingController(text: widget.store.baseUrl);

  String? _connectionMessage;
  bool _connectionOk = false;
  bool _testing = false;

  File? _photo;
  bool _saving = false;
  String? _error;

  String get _url => _urlController.text.trim().replaceAll(RegExp(r'/$'), '');

  @override
  void initState() {
    super.initState();
    // Re-check on open so returning users see the current state immediately.
    _testConnection();
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _connectionMessage = null;
    });

    try {
      final health = await ApiClient(_url).health();
      setState(() {
        _connectionOk = health.configured;
        _connectionMessage = health.configured
            ? 'Connected${health.units == null ? '' : ' · ${health.units} units left'}'
            : 'Reached the backend, but it has no YouCam API key';
      });
    } catch (_) {
      setState(() {
        _connectionOk = false;
        _connectionMessage = 'Could not reach $_url';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _pickPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1600,
      imageQuality: 92,
    );
    if (picked != null) setState(() => _photo = File(picked.path));
  }

  Future<void> _save() async {
    final hasExistingPhoto = widget.store.hasModel;
    if (_photo == null && !hasExistingPhoto) {
      setState(() => _error = 'Add a full-body photo to finish');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      if (_url != widget.store.baseUrl) await widget.store.setBaseUrl(_url);
      if (_photo != null) await widget.store.uploadModel(await _photo!.readAsBytes());
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final photoDone = _photo != null || store.hasModel;

    return Scaffold(
      appBar: AppBar(title: const Text('Setup')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          _step(
            context,
            number: 1,
            title: 'Connect to your backend',
            done: _connectionOk,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your phone and computer need to be on the same Wi-Fi. The YouCam '
                  'API key stays on the computer and never reaches this app.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _urlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Backend address',
                    hintText: 'http://192.168.0.240:8787',
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _testing ? null : _testConnection,
                  child: Text(_testing ? 'Testing…' : 'Test connection'),
                ),
                if (_connectionMessage != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        _connectionOk ? Icons.check_circle : Icons.error_outline,
                        size: 18,
                        color: _connectionOk
                            ? const Color(0xFF19B36B)
                            : Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_connectionMessage!,
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 26),

          _step(
            context,
            number: 2,
            title: 'Add your photo',
            done: photoDone,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Full body, facing forward, plain background. Everything you try '
                  'on gets rendered onto this one photo.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
                ),
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: _pickPhoto,
                  child: Container(
                    height: 250,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _photo != null
                        ? Image.file(_photo!, fit: BoxFit.cover)
                        : store.modelUrl != null
                            ? Stack(
                                fit: StackFit.expand,
                                children: [
                                  Image.network(store.modelUrl!, fit: BoxFit.cover),
                                  const Positioned(
                                    right: 10,
                                    top: 10,
                                    child: Pill(label: 'CURRENT', icon: Icons.check),
                                  ),
                                ],
                              )
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_a_photo_outlined,
                                      size: 30,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.5)),
                                  const SizedBox(height: 10),
                                  const Text('Choose a photo'),
                                ],
                              ),
                  ),
                ),
              ],
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 18),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],

          const SizedBox(height: 30),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Done'),
          ),
        ],
      ),
    );
  }

  Widget _step(
    BuildContext context, {
    required int number,
    required String title,
    required bool done,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done ? const Color(0xFF19B36B) : scheme.primary.withValues(alpha: 0.12),
              ),
              child: done
                  ? const Icon(Icons.check, size: 17, color: Colors.white)
                  : Center(
                      child: Text(
                        '$number',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: scheme.primary,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 14),
        Padding(padding: const EdgeInsets.only(left: 40), child: child),
      ],
    );
  }
}
