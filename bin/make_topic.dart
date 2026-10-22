// Prints a fresh keyed topic's uconn:// link; for the E2E scripts.
import 'package:uconnect_mobile/uconnect/uconnect.dart';

void main() {
  // ignore: avoid_print
  print(TopicCreds.generate().toUri());
}
