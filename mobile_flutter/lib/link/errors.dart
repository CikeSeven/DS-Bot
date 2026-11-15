/// An error that carries the link's or the computer's error code, like the
/// `{ code }` the TypeScript link attaches to its errors.
class LinkError implements Exception {
  LinkError(this.code, this.message);

  final String? code;
  final String message;

  @override
  String toString() => code == null ? message : '$message ($code)';
}
