@Deprecated(
  'This should no longer be used. '
  'Will be removed in the next versions.',
)
abstract class Serializer<T> {
  const Serializer();
  String toJson(T data);
  T fromJson(String json);
}
