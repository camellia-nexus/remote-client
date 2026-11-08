// https://github.com/rodrigobastosv/fancy_password_field
import 'package:flutter/material.dart';
import 'package:camellia_remote_app/common.dart';
import 'package:get/get.dart';
import 'package:password_strength/password_strength.dart';

abstract class ValidationRule {
  String get name;
  bool validate(String value);
}

class UppercaseValidationRule extends ValidationRule {
  @override
  String get name => translate('uppercase');
  @override
  bool validate(String value) {
    return value.runes.any((int rune) {
      var character = String.fromCharCode(rune);
      return character.toUpperCase() == character &&
          character.toLowerCase() != character;
    });
  }
}

class LowercaseValidationRule extends ValidationRule {
  @override
  String get name => translate('lowercase');

  @override
  bool validate(String value) {
    return value.runes.any((int rune) {
      var character = String.fromCharCode(rune);
      return character.toLowerCase() == character &&
          character.toUpperCase() != character;
    });
  }
}

class DigitValidationRule extends ValidationRule {
  @override
  String get name => translate('digit');

  @override
  bool validate(String value) {
    return value.contains(RegExp(r'[0-9]'));
  }
}

class SpecialCharacterValidationRule extends ValidationRule {
  @override
  String get name => translate('special character');

  @override
  bool validate(String value) {
    return value.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>]'));
  }
}

class MinCharactersValidationRule extends ValidationRule {
  final int _numberOfCharacters;
  MinCharactersValidationRule(this._numberOfCharacters);

  @override
  String get name => translate('length>={$_numberOfCharacters}');

  @override
  bool validate(String value) {
    return value.length >= _numberOfCharacters;
  }
}

class PasswordStrengthIndicator extends StatelessWidget {
  final RxString password;
  final double weakMedium = 0.33;
  final double mediumStrong = 0.67;
  const PasswordStrengthIndicator({super.key, required this.password});

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final strength = estimatePasswordStrength(password.value);
      final activeColor = _getColor(context, strength);
      final inactiveColor = Theme.of(context).colorScheme.surfaceContainerHigh;
      final activeSegments = password.isEmpty
          ? 0
          : strength < weakMedium
          ? 1
          : strength < mediumStrong
          ? 2
          : 3;
      final label = password.isEmpty ? '' : translate(_getLabel(strength));
      return Semantics(
        liveRegion: true,
        label: label,
        child: Row(
          children: [
            for (var index = 0; index < 3; index++) ...[
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  height: 7,
                  decoration: BoxDecoration(
                    color: index < activeSegments ? activeColor : inactiveColor,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              if (index < 2) const SizedBox(width: 5),
            ],
            if (label.isNotEmpty) ...[
              const SizedBox(width: 10),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: activeColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      );
    });
  }

  String _getLabel(double strength) {
    if (strength < weakMedium) {
      return 'Weak';
    } else if (strength < mediumStrong) {
      return 'Medium';
    } else {
      return 'Strong';
    }
  }

  Color _getColor(BuildContext context, double strength) {
    if (strength < weakMedium) {
      return AppVisual.tone(context, AppTone.danger);
    } else if (strength < mediumStrong) {
      return AppVisual.tone(context, AppTone.warning);
    } else {
      return AppVisual.tone(context, AppTone.success);
    }
  }
}
