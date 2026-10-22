import 'package:flutter_test/flutter_test.dart';
import 'package:uconnect_mobile/core/storage/storage_client.dart';
import 'package:uconnect_mobile/core/storage/storage_offerer.dart';

void main() {
  test('remote names are cleaned before use as local file names (5.11)', () {
    expect(safeLocalName('report.txt'), 'report.txt');
    expect(safeLocalName('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
    expect(safeLocalName('  spaced  '), 'spaced');
    expect(safeLocalName('dots...'), 'dots');
    expect(safeLocalName('trail. . '), 'trail');
    expect(safeLocalName(''), 'download');
    expect(safeLocalName('...'), 'download');
    expect(safeLocalName('CON'), '_CON');
    expect(safeLocalName('nul.txt'), '_nul.txt');
    expect(safeLocalName('COM7.log'), '_COM7.log');
    expect(safeLocalName('x' * 300).length, 200);
    expect(safeLocalName('tab\tname'), 'tab_name');
  });

  test('upload names must survive the filter unchanged (5.6)', () {
    expect(isCleanUploadName('report.txt'), isTrue);
    expect(isCleanUploadName('bad:name'), isFalse);
    expect(isCleanUploadName('ends.'), isFalse);
    expect(isCleanUploadName(''), isFalse);
    expect(isCleanUploadName('CON'), isFalse);
  });

  test('the offerer refuses its own temp-file prefix as an upload name', () {
    expect(isCleanName('.ucupload-7'), isFalse);
    expect(isCleanName('normal.bin'), isTrue);
  });
}
