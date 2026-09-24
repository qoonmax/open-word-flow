#ifndef OPEN_WORD_FLOW_RECORDING_NATIVE_DARWIN_H
#define OPEN_WORD_FLOW_RECORDING_NATIVE_DARWIN_H

typedef struct owf_native_recorder owf_native_recorder;

int owf_microphone_permission(void);
owf_native_recorder *owf_recorder_start(const char *path, char **error_message);
void owf_recorder_stop(owf_native_recorder *handle);
float owf_recorder_level(owf_native_recorder *handle);

#endif
