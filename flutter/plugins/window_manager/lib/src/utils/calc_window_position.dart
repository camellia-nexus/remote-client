import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';

Future<Offset> calcWindowPosition(
  Size windowSize,
  Alignment alignment,
) async {
  Display? primaryDisplay;
  List<Display> allDisplays = const <Display>[];
  Offset? cursorScreenPoint;

  try {
    primaryDisplay = await screenRetriever
        .getPrimaryDisplay()
        .timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint("Failed to get primary display: $e");
  }

  try {
    allDisplays = await screenRetriever
        .getAllDisplays()
        .timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint("Failed to get all displays: $e");
  }

  try {
    cursorScreenPoint = await screenRetriever
        .getCursorScreenPoint()
        .timeout(const Duration(seconds: 2));
  } catch (e) {
    debugPrint("Failed to get cursor screen point: $e");
  }

  primaryDisplay ??= Display(
    id: 0,
    name: 'fallback',
    size: const Size(1920, 1080),
    visiblePosition: const Offset(0, 0),
    visibleSize: const Size(1920, 1080),
    scaleFactor: 1.0,
  );

  cursorScreenPoint ??= const Offset(0, 0);

  Display currentDisplay = allDisplays.firstWhere(
    (display) {
      final pos = display.visiblePosition ?? const Offset(0, 0);
      return Rect.fromLTWH(
        pos.dx,
        pos.dy,
        display.size.width,
        display.size.height,
      ).contains(cursorScreenPoint!);
    },
    orElse: () => primaryDisplay!,
  );

  num visibleWidth = currentDisplay.size.width;
  num visibleHeight = currentDisplay.size.height;
  num visibleStartX = 0;
  num visibleStartY = 0;

  if (currentDisplay.visibleSize != null) {
    visibleWidth = currentDisplay.visibleSize!.width;
    visibleHeight = currentDisplay.visibleSize!.height;
  }
  if (currentDisplay.visiblePosition != null) {
    visibleStartX = currentDisplay.visiblePosition!.dx;
    visibleStartY = currentDisplay.visiblePosition!.dy;
  }
  Offset position = const Offset(0, 0);

  if (alignment == Alignment.topLeft) {
    position = Offset(
      visibleStartX + 0,
      visibleStartY + 0,
    );
  } else if (alignment == Alignment.topCenter) {
    position = Offset(
      visibleStartX + (visibleWidth / 2) - (windowSize.width / 2),
      visibleStartY + 0,
    );
  } else if (alignment == Alignment.topRight) {
    position = Offset(
      visibleStartX + visibleWidth - windowSize.width,
      visibleStartY + 0,
    );
  } else if (alignment == Alignment.centerLeft) {
    position = Offset(
      visibleStartX + 0,
      visibleStartY + ((visibleHeight / 2) - (windowSize.height / 2)),
    );
  } else if (alignment == Alignment.center) {
    position = Offset(
      visibleStartX + (visibleWidth / 2) - (windowSize.width / 2),
      visibleStartY + ((visibleHeight / 2) - (windowSize.height / 2)),
    );
  } else if (alignment == Alignment.centerRight) {
    position = Offset(
      visibleStartX + visibleWidth - windowSize.width,
      visibleStartY + ((visibleHeight / 2) - (windowSize.height / 2)),
    );
  } else if (alignment == Alignment.bottomLeft) {
    position = Offset(
      visibleStartX + 0,
      visibleStartY + (visibleHeight - windowSize.height),
    );
  } else if (alignment == Alignment.bottomCenter) {
    position = Offset(
      visibleStartX + (visibleWidth / 2) - (windowSize.width / 2),
      visibleStartY + (visibleHeight - windowSize.height),
    );
  } else if (alignment == Alignment.bottomRight) {
    position = Offset(
      visibleStartX + visibleWidth - windowSize.width,
      visibleStartY + (visibleHeight - windowSize.height),
    );
  }
  return position;
}
