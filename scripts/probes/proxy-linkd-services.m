#import <Foundation/Foundation.h>
#include <xpc/xpc.h>

static const char *g_services[] = {
    "com.apple.intents.intents-helper",
    "com.apple.linkd.registry",
    "com.apple.linkd.transcript.privileged",
    "com.apple.linkd.transcript.observing",
    "com.apple.linkd.synchronizeMetadataStore",
    "com.apple.linkd.update-registry",
    "com.apple.linkd.prune-transcript",
    "com.apple.link.XPCEventDispatcher",
    "com.apple.appIntents.relevantIntentProvided",
    "com.apple.CascadeSets.DonateNow",
    NULL,
};

void try_connect(const char *svc) {
    xpc_connection_t conn = xpc_connection_create_mach_service(svc, NULL, 0);
    if (!conn) { printf("  [%s] no connection object\n", svc); return; }
    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {});
    xpc_connection_activate(conn);
    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *result = nil;
    xpc_connection_send_message_with_reply(conn, msg, dispatch_get_main_queue(), ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
            const char *desc = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);
            result = [NSString stringWithUTF8String:(desc ? desc : "?")];
        } else {
            result = [NSString stringWithFormat:@"OK reply type %s", xpc_type_get_name(xpc_get_type(reply))];
        }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
    xpc_connection_cancel(conn);
    printf("  [%s] %s\n", svc, [result UTF8String]);
}

int main() {
    dispatch_queue_t q = dispatch_queue_create("probe", DISPATCH_QUEUE_SERIAL);
    dispatch_async(q, ^{
        for (int i = 0; g_services[i]; i++) {
            try_connect(g_services[i]);
        }
        exit(0);
    });
    dispatch_main();
    return 0;
}
