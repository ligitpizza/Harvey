import 'package:flutter/material.dart';

import '../../core/utils/ic_number.dart';

/// D-103: "MyKad or passport number", with Nationality appearing once a passport is
/// typed. A MyKad shows the birthday and gender read from it. Used at sign-up, onboarding
/// gaps, walk-in and admin registration, and in the patient's profile.
class IdentityFields extends StatefulWidget {
  const IdentityFields({
    super.key,
    required this.id,
    required this.nationality,
    this.required = true,
    this.idKey = const Key('identity-number'),
    this.nationalityKey = const Key('identity-nationality'),
    this.preview,
    this.helperText,
    this.onParsed,
  });

  final TextEditingController id;
  final TextEditingController nationality;
  final bool required;
  final Key idKey;
  final Key nationalityKey;

  /// e.g. "Born 1 Jan 1990 · Male" for a MyKad; null hides it.
  final String? Function(IdInfo info)? preview;
  final String? helperText;

  /// Called as soon as the field holds a valid number (e.g. to fill in the birthday).
  final ValueChanged<IdInfo>? onParsed;

  @override
  State<IdentityFields> createState() => _IdentityFieldsState();
}

class _IdentityFieldsState extends State<IdentityFields> {
  IdInfo? get _info {
    try {
      return parseIdentity(widget.id.text);
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final passport = looksLikePassport(widget.id.text);
    final info = _info;
    final shown = info == null
        ? widget.helperText
        : info.isPassport
        ? 'Passport'
        : (widget.preview?.call(info) ?? 'MyKad');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: widget.idKey,
          controller: widget.id,
          keyboardType: TextInputType.visiblePassword, // letters and digits, no autocorrect
          autocorrect: false,
          inputFormatters: [IdInputFormatter()],
          decoration: InputDecoration(
            labelText: 'MyKad or passport number',
            hintText: '900101-14-5678 or A12345678',
            helperText: shown,
            helperMaxLines: 2,
          ),
          onChanged: (_) {
            setState(() {});
            final info = _info;
            if (info != null) widget.onParsed?.call(info);
          },
          autovalidateMode: AutovalidateMode.onUserInteraction,
          validator: (v) => validateIdentity(v, required: widget.required),
        ),
        if (passport) ...[
          const SizedBox(height: 12),
          TextFormField(
            key: widget.nationalityKey,
            controller: widget.nationality,
            textCapitalization: TextCapitalization.words,
            maxLength: 60,
            decoration: const InputDecoration(
              labelText: 'Nationality (as on the passport)',
              counterText: '',
            ),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Enter the nationality shown on the passport.' : null,
          ),
        ],
      ],
    );
  }
}
