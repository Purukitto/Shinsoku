import 'package:flutter_test/flutter_test.dart';
import 'package:shinsoku/src/models/links.dart';

void main() {
  group('isLink', () {
    test('takes a bare link', () {
      expect(isLink('https://example.com/a.zip'), isTrue);
      expect(isLink('http://example.com'), isTrue);
    });

    test('refuses other text', () {
      expect(isLink('see https://example.com/a.zip'), isFalse);
      expect(isLink('https://example.com/a b.zip'), isFalse);
      expect(isLink('ftp://example.com/a.zip'), isFalse);
      expect(isLink(''), isFalse);
    });
  });

  group('findLink', () {
    test('finds a link inside shared text', () {
      expect(
        findLink('Ubuntu 24.04 — https://releases.ubuntu.com/24.04/ubuntu.iso'),
        'https://releases.ubuntu.com/24.04/ubuntu.iso',
      );
      expect(findLink('first http://a.example/1 then https://b.example/2'), 'http://a.example/1');
    });

    test('leaves off trailing punctuation', () {
      expect(findLink('Get it at https://example.com/a.zip.'), 'https://example.com/a.zip');
      expect(findLink('(https://example.com/a.zip)'), 'https://example.com/a.zip');
      expect(findLink('"https://example.com/a.zip",'), 'https://example.com/a.zip');
    });

    test('keeps a bracket the link opened', () {
      expect(
        findLink('https://en.wikipedia.org/wiki/Bolt_(lightning)'),
        'https://en.wikipedia.org/wiki/Bolt_(lightning)',
      );
      expect(
        findLink('(see https://en.wikipedia.org/wiki/Bolt_(lightning))'),
        'https://en.wikipedia.org/wiki/Bolt_(lightning)',
      );
    });

    test('is null without a link', () {
      expect(findLink('just some words'), isNull);
      expect(findLink('https://'), isNull);
      expect(findLink('https://.'), isNull);
    });
  });
}
