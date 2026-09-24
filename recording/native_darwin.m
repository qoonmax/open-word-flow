#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "native_darwin.h"

struct owf_native_recorder {
    AVAudioRecorder *recorder;
};

static void owf_set_error(char **error_message, NSString *message) {
    if (error_message == NULL) {
        return;
    }

    const char *text = message != nil ? message.UTF8String : "unknown AVFoundation error";
    *error_message = strdup(text);
}

int owf_microphone_permission(void) {
    @autoreleasepool {
        AVAuthorizationStatus status =
            [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];

        if (status == AVAuthorizationStatusAuthorized) {
            return 1;
        }

        if (status == AVAuthorizationStatusDenied ||
            status == AVAuthorizationStatusRestricted) {
            return 0;
        }

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block BOOL granted = NO;

        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                completionHandler:^(BOOL allowed) {
                                    granted = allowed;
                                    dispatch_semaphore_signal(semaphore);
                                }];

        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

#if !OS_OBJECT_USE_OBJC
        dispatch_release(semaphore);
#endif

        return granted ? 1 : 0;
    }
}

owf_native_recorder *owf_recorder_start(const char *path, char **error_message) {
    @autoreleasepool {
        NSString *filePath = [NSString stringWithUTF8String:path];
        NSURL *url = [NSURL fileURLWithPath:filePath];
        NSDictionary *settings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @16000.0,
            AVNumberOfChannelsKey: @1,
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO
        };

        NSError *error = nil;
        AVAudioRecorder *recorder =
            [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];

        if (recorder == nil) {
            owf_set_error(error_message, error.localizedDescription);
            return NULL;
        }

        recorder.meteringEnabled = YES;

        if (![recorder prepareToRecord]) {
            owf_set_error(error_message, @"AVAudioRecorder could not prepare the microphone");
            [recorder release];
            return NULL;
        }

        if (![recorder record]) {
            owf_set_error(error_message, @"AVAudioRecorder could not start the microphone");
            [recorder release];
            return NULL;
        }

        owf_native_recorder *handle = calloc(1, sizeof(owf_native_recorder));
        if (handle == NULL) {
            [recorder stop];
            [recorder release];
            owf_set_error(error_message, @"could not allocate recorder state");
            return NULL;
        }

        handle->recorder = recorder;
        return handle;
    }
}

void owf_recorder_stop(owf_native_recorder *handle) {
    if (handle == NULL) {
        return;
    }

    @autoreleasepool {
        [handle->recorder stop];
        [handle->recorder release];
        free(handle);
    }
}

// Returns the average input level mapped from [-50 dB, 0 dB] to [0, 1].
float owf_recorder_level(owf_native_recorder *handle) {
    if (handle == NULL) {
        return 0;
    }

    @autoreleasepool {
        [handle->recorder updateMeters];
        float level = ([handle->recorder averagePowerForChannel:0] + 50.0f) / 50.0f;

        return fminf(fmaxf(level, 0.0f), 1.0f);
    }
}
