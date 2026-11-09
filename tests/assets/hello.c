/* Tiny smoke test compiled with the module-provided C compiler. */
#include <stdio.h>
int main(void) {
#ifdef __INTEL_LLVM_COMPILER
    printf("hello from icx\n");
#else
    printf("hello from cc\n");
#endif
    return 0;
}
