#if defined(TERMPLEX_SIMD_VT_H_) == defined(HWY_TARGET_TOGGLE)
#ifdef TERMPLEX_SIMD_VT_H_
#undef TERMPLEX_SIMD_VT_H_
#else
#define TERMPLEX_SIMD_VT_H_
#endif

#include <hwy/highway.h>

HWY_BEFORE_NAMESPACE();
namespace termplex {
namespace HWY_NAMESPACE {

namespace hn = hwy::HWY_NAMESPACE;

}  // namespace HWY_NAMESPACE
}  // namespace termplex
HWY_AFTER_NAMESPACE();

#if HWY_ONCE

namespace termplex {

typedef void (*PrintFunc)(const char32_t* chars, size_t count);

}  // namespace termplex

#endif  // HWY_ONCE

#endif  // TERMPLEX_SIMD_VT_H_
