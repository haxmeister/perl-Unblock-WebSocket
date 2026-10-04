#ifndef UNBLOCK_WEBSOCKET_NATIVE_H
#define UNBLOCK_WEBSOCKET_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#define UNBLOCK_WEBSOCKET_NATIVE_ABI_VERSION 1U

#define UNBLOCK_WEBSOCKET_ROLE_CLIENT 1U
#define UNBLOCK_WEBSOCKET_ROLE_SERVER 2U

#define UNBLOCK_WEBSOCKET_EVENT_TEXT   1U
#define UNBLOCK_WEBSOCKET_EVENT_BINARY 2U
#define UNBLOCK_WEBSOCKET_EVENT_CLOSE  8U
#define UNBLOCK_WEBSOCKET_EVENT_PING   9U
#define UNBLOCK_WEBSOCKET_EVENT_PONG   10U

#define UNBLOCK_WEBSOCKET_OK 0
#define UNBLOCK_WEBSOCKET_CALLBACK_STOP 1
#define UNBLOCK_WEBSOCKET_ERROR -1

typedef int (*unblock_websocket_event_fn)(
    void *user,
    uint32_t event,
    const char *data,
    size_t length
);

typedef struct unblock_websocket_native_ops_v1_s {
    uint32_t abi_version;
    size_t struct_size;
    const char *name;

    void *(*create)(uint32_t role, size_t max_message_size);
    void (*destroy)(void *context);

    int (*input)(
        void *context,
        const char *data,
        size_t length,
        size_t *consumed,
        unblock_websocket_event_fn event_fn,
        void *event_user
    );

    int (*send)(
        void *context,
        uint32_t opcode,
        const char *data,
        size_t length
    );

    int (*close)(
        void *context,
        uint32_t status_code,
        const char *reason,
        size_t reason_length
    );

    size_t (*output)(void *context, char *buffer, size_t capacity);
    uint32_t (*error_code)(void *context);
    const char *(*error_string)(void *context);
    size_t (*memory_used)(void *context);
} unblock_websocket_native_ops_v1_t;

#define UNBLOCK_WEBSOCKET_NATIVE_OPS_V1_REQUIRED_SIZE     (offsetof(unblock_websocket_native_ops_v1_t, memory_used)         + sizeof(((unblock_websocket_native_ops_v1_t *)0)->memory_used))

#endif
