import 'package:flutter/material.dart';

/// Colors a device can broadcast. Only the index goes over the wire and
/// peers look it up locally, so treat this list as append-only.
const List<Color> kPeerColors = [
  Color(0xFF26A69A), // teal
  Color(0xFF5C6BC0), // indigo
  Color(0xFFEF6C00), // orange
  Color(0xFFD81B60), // pink
  Color(0xFF43A047), // green
  Color(0xFF8E24AA), // purple
];

Color peerColor(int index) => kPeerColors[index.abs() % kPeerColors.length];
