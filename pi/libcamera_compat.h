/* Pi의 libcamera 0.7(Raspberry Pi OS, Debian 13)은 libcamera::Span을 없애고 std::span(C++20)을 씀.
 * R2026b Raspberry Pi Blockset의 카메라 소스(MW_Libcamera.cpp)는 아직 libcamera::Span을 쓰므로 별칭을 만듦.
 * pi_postcodegen.m이 빌드 폴더로 복사하고 -include로 모든 소스 앞에 넣음 (C 파일에서는 아무것도 안 함). */
#ifndef LIBCAMERA_COMPAT_H
#define LIBCAMERA_COMPAT_H
#ifdef __cplusplus
/* C++20 이상에서만 (std::span이 C++20). 공유 유틸리티처럼 -std=c++17로 컴파일되는 소스에서는 아무것도 안 함 */
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
