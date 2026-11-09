/* netCDF runtime smoke test: create a small file, read it back. */
#include <netcdf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define check(err, what) do {                                             \
        int status_ = (err);                                              \
        if (status_ != NC_NOERR) {                                        \
            fprintf(stderr, "%s failed: %s\n", what, nc_strerror(status_));\
            exit(1);                                                      \
        }                                                                 \
    } while (0)

int main(void) {
    int ncid, dimid, varid;
    static const char path[] = "/tmp/automod-nc-test.nc";
    double data[4] = {1.0, 2.0, 3.0, 4.0};
    double back[4] = {0};

    check(nc_create(path, NC_CLOBBER, &ncid), "create");
    check(nc_def_dim(ncid, "x", 4, &dimid), "def_dim");
    check(nc_def_var(ncid, "vals", NC_DOUBLE, 1, &dimid, &varid), "def_var");
    check(nc_enddef(ncid), "enddef");
    check(nc_put_var_double(ncid, varid, data), "put_var");
    check(nc_close(ncid), "close");

    check(nc_open(path, NC_NOWRITE, &ncid), "open");
    check(nc_inq_varid(ncid, "vals", &varid), "inq_varid");
    check(nc_get_var_double(ncid, varid, back), "get_var");
    check(nc_close(ncid), "close2");

    if (back[3] != 4.0) {
        printf("MISMATCH %f\n", back[3]);
        return 1;
    }
    printf("netcdf smoke test ok\n");
    return 0;
}
