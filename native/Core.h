#include <stdbool.h>
#include <stdint.h>
typedef struct { double x, y, width, height; } HarborRect;
HarborRect harbor_place(HarborRect window, HarborRect screen);
bool harbor_should_run(bool enabled, bool trusted, uint32_t external_count, bool changed);
