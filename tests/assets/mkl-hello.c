/* Intel MKL runtime smoke test: 2x2 sgemm via the single dynamic library
 * (libmkl_rt). Compile with gcc -lmkl_rt and run with
 * MKL_THREADING_LAYER=GNU (no Intel OpenMP runtime needed). */
#include <mkl.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    /* C = A * B, all 2x2 row-major */
    float a[4] = {1.0f, 2.0f, 3.0f, 4.0f};
    float b[4] = {5.0f, 6.0f, 7.0f, 8.0f};
    float c[4] = {0.0f, 0.0f, 0.0f, 0.0f};

    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                2, 2, 2, 1.0f, a, 2, b, 2, 0.0f, c, 2);

    /* expected: [[19, 22], [43, 50]] */
    if (c[0] != 19.0f || c[1] != 22.0f || c[2] != 43.0f || c[3] != 50.0f) {
        fprintf(stderr, "MKL sgemm mismatch: %g %g %g %g\n",
                (double)c[0], (double)c[1], (double)c[2], (double)c[3]);
        return 1;
    }
    printf("mkl smoke test ok\n");
    return 0;
}
