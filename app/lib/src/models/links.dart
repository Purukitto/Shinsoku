/// Whether [text] is a single `http(s)` link and nothing else: what a copied link
/// looks like, as opposed to copied prose that happens to contain one.
bool isLink(String text) =>
    (text.startsWith('http://') || text.startsWith('https://')) && !text.contains(_space);

/// The first `http(s)` link in [text], or null. Apps share a link inside other
/// words ("Title — https://…"), and prose ends it with a full stop or wraps it in
/// brackets, so trailing punctuation is left off; a closing bracket the link
/// itself opened stays.
String? findLink(String text) {
  final match = _link.firstMatch(text);
  if (match == null) return null;
  var link = match[0]!;
  while (link.isNotEmpty) {
    final last = link[link.length - 1];
    final strayBracket = last == ')' && ')'.allMatches(link).length > '('.allMatches(link).length;
    if (!_trailing.contains(last) && !strayBracket) break;
    link = link.substring(0, link.length - 1);
  }
  return link.length > link.indexOf('//') + 2 ? link : null;
}

final _space = RegExp(r'\s');
final _link = RegExp(r'https?://\S+');
const _trailing = '.,;:!?\'">]»”’';
