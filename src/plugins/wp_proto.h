#ifndef WAVE_WP_PROTO_H
#define WAVE_WP_PROTO_H

#include <stdint.h>

enum {
    WP_OP_PROCESS = 1,
    WP_OP_SET_PARAM,
    WP_OP_GET_PARAMS,
    WP_OP_SAVE_STATE,
    WP_OP_LOAD_STATE,
    WP_OP_SHOW_UI,
    WP_OP_QUIT
};

enum {
    WP_FLAG_HAS_UI = 1,
    WP_FLAG_UI_VISIBLE = 2
};

typedef struct {
    uint32_t op;
    int32_t index;
    int32_t frames;
    int32_t pad;
    double value;
    uint64_t len;
} WpMsg;

typedef struct {
    int32_t status;
    int32_t ivalue;
    int32_t flags;
    int32_t pad;
    double value;
    uint64_t len;
} WpReply;

#define WP_SOCKET_FD 3
#define WP_SHM_FD 4

#endif
