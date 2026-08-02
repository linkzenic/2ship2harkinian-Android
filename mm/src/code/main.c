#ifdef _WIN32
#include <Windows.h>
#include <stdio.h>
#include <locale.h>
#endif

#include "audiomgr.h"
#include "fault.h"
#include "idle.h"
#include "irqmgr.h"
#include "padmgr.h"
#include "scheduler.h"
#include "CIC6105.h"
#include "stack.h"
#include "stackcheck.h"
#include "BenPort.h"
#include <libultraship/bridge/crashhandlerbridge.h>

// Variables are put before most headers as a hacky way to bypass bss reordering
OSMesgQueue sSerialEventQueue;
OSMesg sSerialMsgBuf[1];
uintptr_t gSegments[NUM_SEGMENTS];
SchedContext gSchedContext;
IrqMgrClient sIrqClient;
OSMesgQueue sIrqMgrMsgQueue;
OSMesg sIrqMgrMsgBuf[60];
OSThread gGraphThread;
STACK(sGraphStack, 0x1800);
STACK(sSchedStack, 0x600);
STACK(sAudioStack, 0x800);
STACK(sPadMgrStack, 0x500);
StackEntry sGraphStackInfo;
StackEntry sSchedStackInfo;
StackEntry sAudioStackInfo;
StackEntry sPadMgrStackInfo;
AudioMgr sAudioMgr;
static s32 sBssPad;
PadMgr gPadMgr;

#include "main.h"
#include "buffers.h"
#include "global.h"
#include "system_heap.h"
#include "z64thread.h"

s32 gScreenWidth = SCREEN_WIDTH;
s32 gScreenHeight = SCREEN_HEIGHT;
size_t gSystemHeapSize = 0;

#ifdef __ANDROID__
#include <jni.h>
#include <SDL.h>
extern void Android_SetDataRootPath(const char* path);

static void update_native_data_root_path(JNIEnv* env) {
    jclass mainActivityClass = (*env)->FindClass(env, "com/twoshipfork/mm/MainActivity");
    if (mainActivityClass == NULL) {
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        }
        return;
    }

    jmethodID getPathMethod =
        (*env)->GetStaticMethodID(env, mainActivityClass, "getDataRootPathFromNative", "()Ljava/lang/String;");
    if (getPathMethod == NULL) {
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        }
        (*env)->DeleteLocalRef(env, mainActivityClass);
        return;
    }

    jstring javaPath = (jstring)(*env)->CallStaticObjectMethod(env, mainActivityClass, getPathMethod);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, mainActivityClass);
        return;
    }

    if (javaPath != NULL) {
        const char* path = (*env)->GetStringUTFChars(env, javaPath, NULL);
        if (path != NULL) {
            Android_SetDataRootPath(path);
            (*env)->ReleaseStringUTFChars(env, javaPath, path);
        }
        (*env)->DeleteLocalRef(env, javaPath);
    }

    (*env)->DeleteLocalRef(env, mainActivityClass);
}

void wait_for_java_setup() {
    JNIEnv* env = SDL_AndroidGetJNIEnv();
    jclass mainActivityClass = (*env)->FindClass(env, "com/twoshipfork/mm/MainActivity");
    if (mainActivityClass == NULL) {
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        }
        return;
    }

    jmethodID waitMethod = (*env)->GetStaticMethodID(env, mainActivityClass, "waitForSetupFromNative", "()V");
    if (waitMethod == NULL) {
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        }
        (*env)->DeleteLocalRef(env, mainActivityClass);
        return;
    }

    (*env)->CallStaticVoidMethod(env, mainActivityClass, waitMethod);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, mainActivityClass);
        return;
    }

    (*env)->DeleteLocalRef(env, mainActivityClass);
    update_native_data_root_path(env);
}
#endif

void InitOTR();
void Heaps_Free(void);

#if defined(__ANDROID__) || defined(__IOS__)
int SDL_main(int argc, char** argv /* void* arg*/) {
#else
int main(int argc, char** argv /* void* arg*/) {
#endif
#ifdef __ANDROID__
    wait_for_java_setup(); // Pause here until Java is ready
#endif
    intptr_t fb;
    intptr_t sysHeap;
    s32 exit;
    s16* msg;

// Attach console for windows so we can conditionally display it when running the extractor
#ifdef _WIN32
    AllocConsole();
    (void)freopen("CONIN$", "r", stdin);
    (void)freopen("CONOUT$", "w", stdout);
    (void)freopen("CONOUT$", "w", stderr);
#ifndef _DEBUG
    ShowWindow(GetConsoleWindow(), SW_HIDE);
#endif
    // Allow non-ascii characters for Windows
    setlocale(LC_ALL, ".UTF8");
#endif // _WIN32

    InitOTR();
    CrashHandlerRegisterCallback(CrashHandler_PrintExt);
    Heaps_Alloc();

    gScreenWidth = SCREEN_WIDTH;
    gScreenHeight = SCREEN_HEIGHT;

    Nmi_Init();
    Fault_Init();
    Check_RegionIsSupported();
    Check_ExpansionPak();
    sysHeap = gSystemHeap;
    // fb = FRAMEBUFFERS_START_ADDR;
    // gSystemHeapSize = fb - sysHeap;
    SystemHeap_Init(sysHeap, SYSTEM_HEAP_SIZE);

    Regs_Init();

    R_ENABLE_ARENA_DBG = 0;

    osCreateMesgQueue(&sSerialEventQueue, sSerialMsgBuf, ARRAY_COUNT(sSerialMsgBuf));
    osSetEventMesg(OS_EVENT_SI, &sSerialEventQueue, OS_MESG_PTR(NULL));

    osCreateMesgQueue(&sIrqMgrMsgQueue, sIrqMgrMsgBuf, ARRAY_COUNT(sIrqMgrMsgBuf));
    PadMgr_Init(&sSerialEventQueue, &gIrqMgr, Z_THREAD_ID_PADMGR, Z_PRIORITY_PADMGR, STACK_TOP(sPadMgrStack));

    AudioMgr_Init(&sAudioMgr, STACK_TOP(sAudioStack), Z_PRIORITY_AUDIOMGR, Z_THREAD_ID_AUDIOMGR, &gSchedContext,
                  &gIrqMgr);
#if 0
    StackCheck_Init(&sSchedStackInfo, sSchedStack, STACK_TOP(sSchedStack), 0, 0x100, "sched");
    Sched_Init(&gSchedContext, STACK_TOP(sSchedStack), Z_PRIORITY_SCHED, gViConfigModeType, 1, &gIrqMgr);

    CIC6105_AddRomInfoFaultPage();

    IrqMgr_AddClient(&gIrqMgr, &sIrqClient, &sIrqMgrMsgQueue);

    StackCheck_Init(&sAudioStackInfo, sAudioStack, STACK_TOP(sAudioStack), 0, 0x100, "audio");
    AudioMgr_Init(&sAudioMgr, STACK_TOP(sAudioStack), Z_PRIORITY_AUDIOMGR, Z_THREAD_ID_AUDIOMGR, &gSchedContext,
                  &gIrqMgr);

    StackCheck_Init(&sPadMgrStackInfo, sPadMgrStack, STACK_TOP(sPadMgrStack), 0, 0x100, "padmgr");

    AudioMgr_Unlock(&sAudioMgr);
    StackCheck_Init(&sGraphStackInfo, sGraphStack, STACK_TOP(sGraphStack), 0, 0x100, "graph");
    osCreateThread(&gGraphThread, Z_THREAD_ID_GRAPH, Graph_ThreadEntry, NULL, STACK_TOP(sGraphStack), Z_PRIORITY_GRAPH);
    osStartThread(&gGraphThread);
#endif

    Graph_ThreadEntry(0);

    exit = false;

    while (!exit) {
        msg = NULL;
        osRecvMesg(&sIrqMgrMsgQueue, (OSMesg*)&msg, OS_MESG_BLOCK);
        if (msg == NULL) {
            break;
        }

        switch (*msg) {
            case OS_SC_PRE_NMI_MSG:
                Nmi_SetPrenmiStart();
                break;

            case OS_SC_NMI_MSG:
                exit = true;
                break;
        }
    }

    IrqMgr_RemoveClient(&gIrqMgr, &sIrqClient);
    osDestroyThread(&gGraphThread);

    DeinitOTR();

#ifdef _WIN32
    FreeConsole();
#endif
    Heaps_Free();
    return 0;
}
