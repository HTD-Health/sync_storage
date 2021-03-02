abstract class Serializer<T> {
  const Serializer();
  String toJson(T data);
  T fromJson(String json);
}
