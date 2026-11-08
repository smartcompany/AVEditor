#pragma once

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

/** Tiny helpers for the fixed plan JSON Kotlin emits (no full JSON parser). */
namespace jsonmini {

inline const char *find_key(const char *json, const char *key) {
  std::string pat = std::string("\"") + key + "\"";
  const char *p = strstr(json, pat.c_str());
  if (!p) return nullptr;
  p = strchr(p + pat.size(), ':');
  if (!p) return nullptr;
  ++p;
  while (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') ++p;
  return p;
}

inline int64_t read_i64(const char *json, const char *key, int64_t fallback = 0) {
  const char *p = find_key(json, key);
  if (!p) return fallback;
  return strtoll(p, nullptr, 10);
}

inline int read_int(const char *json, const char *key, int fallback = 0) {
  return static_cast<int>(read_i64(json, key, fallback));
}

inline float read_f(const char *json, const char *key, float fallback = 0.f) {
  const char *p = find_key(json, key);
  if (!p) return fallback;
  return strtof(p, nullptr);
}

inline std::string read_string(const char *json, const char *key) {
  const char *p = find_key(json, key);
  if (!p || *p != '"') return {};
  ++p;
  std::string out;
  while (*p && *p != '"') {
    if (*p == '\\' && p[1]) {
      out.push_back(p[1]);
      p += 2;
      continue;
    }
    out.push_back(*p++);
  }
  return out;
}

/** Extract object slices for array key. Each entry is a {...} substring. */
inline std::vector<std::string> read_object_array(const char *json, const char *key) {
  std::vector<std::string> out;
  const char *p = find_key(json, key);
  if (!p || *p != '[') return out;
  ++p;
  while (*p) {
    while (*p && *p != '{' && *p != ']') ++p;
    if (*p == ']' || !*p) break;
    const char *start = p;
    int depth = 0;
    do {
      if (*p == '{') depth++;
      else if (*p == '}') depth--;
      ++p;
    } while (*p && depth > 0);
    out.emplace_back(start, p - start);
    while (*p && *p != '{' && *p != ']') ++p;
    if (*p == ']') break;
  }
  return out;
}

}  // namespace jsonmini
