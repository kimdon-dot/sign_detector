/* libcamera 0.7은 libcamera::Span 대신 std::span을 쓰는데, Pi 카메라 블록 소스는 아직 libcamera::Span을 씀 → 별칭.
 * pi_postcodegen.m이 -include로 모든 소스 앞에 넣음 */
#ifndef LIBCAMERA_COMPAT_H
#define LIBCAMERA_COMPAT_H
#ifdef __cplusplus
/* C++20 이상에서만 (C++17 소스에서는 아무것도 안 함) */
#if __cplusplus >= 202002L && !__has_include(<libcamera/span.h>) && __has_include(<span>)
#include <cstddef>
#include <span>
namespace libcamera {
template <typename T, std::size_t Extent = std::dynamic_extent>
using Span = std::span<T, Extent>;
}
#endif
#endif
#endif
