//
//  common_ret.m
//  dylib_dobby_hook
//
//  Created by voidm on 2024/4/9.
//

#include "common_ret.h"
#import <Foundation/Foundation.h>
#import "Constant.h"
#import "MemoryUtils.h"
#include <mach-o/dyld.h>
#include <sys/ptrace.h>
#import <sys/sysctl.h>
#include <mach/mach_types.h>
#import <pthread.h>


int ret2 (void){
    printf(">>>>>> ret2\n");
    return 2;
}
int ret1 (void){
//    uint8_t ret1Hex[6] = {0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3}; // mov eax, 1; ret
//    uint8_t ret1HexARM[8] = {0x20, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6}; // mov x0, #1; ret
    printf(">>>>>> ret1\n");
    return 1;
}
int ret0 (void){
//    uint8_t ret0Hex[3] = {0x31, 0xC0, 0xC3}; // xor eax, eax; ret
//    uint8_t ret0HexARM[8] = {0x00, 0x00, 0x80, 0xD2, 0xC0, 0x03, 0x5F, 0xD6}; // mov x0, #0; ret
    printf(">>>>>> ret0\n");
    return 0;
}

void ret(void){
//    uint8_t retHex[1] = {0xC3}; // ret
//    uint8_t retHexARM[4] = {0xC0, 0x03, 0x5F, 0xD6}; // ret
    printf(">>>>>> ret\n");
}


// hook ptrace
// 通过 ptrace 来检测当前进程是否被调试，通过检查 PT_DENY_ATTACH 标记是否被设置来判断。如果检测到该标记，说明当前进程正在被调试，可以采取相应的反调试措施。
ptrace_ptr_t orig_ptrace = NULL;
int my_ptrace(int _request, pid_t _pid, caddr_t _addr, int _data) {
    if(_request != 31){
        // 如果请求不是 PT_DENY_ATTACH，则调用原始的 ptrace 函数
        return orig_ptrace(_request,_pid,_addr,_data);
    }
    printf(">>>>>> [AntiAntiDebug] - ptrace request is PT_DENY_ATTACH\n");
    // 拒绝调试
    return 0;
}

// hook sysctl
// 通过 sysctl 去查看当前进程的信息，看有没有这个标记位即可检查当前调试状态。
sysctl_ptr_t orig_sysctl = NULL;
int my_sysctl(int * name, u_int namelen, void * info, size_t * infosize, void * newinfo, size_t newinfosize){
    int ret = orig_sysctl(name,namelen,info,infosize,newinfo,newinfosize);
    if(namelen == 4 && name[0] == 1 && name[1] == 14 && name[2] == 1){
        struct kinfo_proc *info_ptr = (struct kinfo_proc *)info;
        if(info_ptr && (info_ptr->kp_proc.p_flag & P_TRACED) != 0){
            NSLog(@">>>>>> [AntiAntiDebug] - sysctl query trace status.");
            info_ptr->kp_proc.p_flag ^= P_TRACED;
            if((info_ptr->kp_proc.p_flag & P_TRACED) == 0){
                NSLog(@">>>>>> [AntiAntiDebug] - trace status reomve success!");
            }
        }
    }
    return ret;
}

// hook task_get_exception_ports
// 通过 task_get_exception_ports 来检查当前任务的异常端口设置，以检测调试器的存在或者检查调试器是否修改了异常端口设置。如果发现异常端口被修改，可能表明调试器介入了目标进程的执行。
// some app will crash with _dyld_debugger_notification
task_get_exception_ports_ptr_t orig_task_get_exception_ports = NULL;
kern_return_t my_task_get_exception_ports
(
 task_inspect_t task,
 exception_mask_t exception_mask,
 exception_mask_array_t masks,
 mach_msg_type_number_t *masksCnt,
 exception_handler_array_t old_handlers,
 exception_behavior_array_t old_behaviors,
 exception_flavor_array_t old_flavors
 ){
    kern_return_t r = orig_task_get_exception_ports(task, exception_mask, masks, masksCnt, old_handlers, old_behaviors, old_flavors);
    for (int i = 0; i < *masksCnt; i++)
    {
        if (old_handlers[i] != 0) {
            old_handlers[i] = 0;
        }
        if (old_flavors[i]  == THREAD_STATE_NONE) {
//             x86_EXCEPTION_STATE
//             x86_EXCEPTION_STATE64
//             ARM_EXCEPTION_STATE
//            #if defined(__arm64__) || defined(__aarch64__)
//            #elif defined(__x86_64__)
//            #endif
            old_flavors[i] = 9;
            NSLog(@">>>>>> [AntiAntiDebug] - my_task_get_exception_ports reset old_flavors[i]=9");
        }
    }
    return r;
}

// hook task_swap_exception_ports
// 通过 task_swap_exception_ports 来动态修改异常处理端口设置，以防止调试器对异常消息进行拦截或修改。例如，恶意软件可以将异常端口设置为自定义的端口，从而阻止调试器捕获异常消息，使调试器无法获取目标进程的状态信息。
task_swap_exception_ports_ptr_t orig_task_swap_exception_ports = NULL;
kern_return_t my_task_swap_exception_ports(
    task_t task,
    exception_mask_t exception_mask,
    mach_port_t new_port,
    exception_behavior_t new_behavior,
    thread_state_flavor_t new_flavor,
    exception_mask_array_t old_masks,
    mach_msg_type_number_t *old_masks_count,
    exception_port_array_t old_ports,
    exception_behavior_array_t old_behaviors,
    thread_state_flavor_array_t old_flavors
) {
    
    // 在这里实现反反调试逻辑，例如阻止特定的异常掩码或端口
   if (exception_mask & EXC_MASK_BREAKPOINT) {
       NSLog(@">>>>>> [AntiAntiDebug] - my_task_swap_exception_ports Breakpoint exception detected, blocking task_swap_exception_ports");
       return KERN_FAILURE; // 返回错误码阻止调用
   }
   return orig_task_swap_exception_ports(task, exception_mask, new_port, new_behavior, new_flavor, old_masks, old_masks_count, old_ports, old_behaviors, old_flavors);
}


// Apple Sec
SecCodeCheckValidityWithErrors_ptr_t SecCodeCheckValidityWithErrors_ori = NULL;
OSStatus hk_SecCodeCheckValidityWithErrors(SecCodeRef code, SecCSFlags flags, SecRequirementRef requirement, CFErrorRef *errors) {
    // anchor apple generic and certificate leaf[subject.OU] = "J3CP9BBBN6"
    // NSString* fakeRequirement = [NSString stringWithFormat:@"identifier \"com.binarynights.ForkLift\""];
    NSLog(@">>>>>> hk_SecCodeCheckValidityWithErrors  requirement = %@", requirement);
    return errSecSuccess;
}
SecCodeCopySigningInformation_ptr_t SecCodeCopySigningInformation_ori = NULL;



// Why do you want to see here ???
NSString *love69(NSString *input) {
    NSMutableString *output = [NSMutableString stringWithCapacity:input.length];
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar ch = [input characterAtIndex:i];

        if (ch >= 'A' && ch <= 'Z') {
            ch = 'A' + (ch - 'A' + 13) % 26;
        } else if (ch >= 'a' && ch <= 'z') {
            ch = 'a' + (ch - 'a' + 13) % 26;
        }
        [output appendFormat:@"%C", ch];
    }
    return output;
}
//char *global_dylib_name = "libdylib_dobby_hook.dylib";


int destory_inject_thread(void){
    // // Ref: https://juejin.cn/post/7277786940170518591
    // At present, the injection thread is judged according to the thread name; it needs to be optimized in the future.
    NSLog(@">>>>>> destory_inject_thread");
    task_t task = mach_task_self();
    thread_act_array_t threads;
    mach_msg_type_number_t threadCount;

    if (task_threads(task, &threads, &threadCount) != KERN_SUCCESS) {
        NSLog(@">>>>>> Failed to get threads.");
        return -1;
    }

    thread_act_t threadsToTerminate[threadCount];
    int terminateCount = 0;
    
    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        thread_t thread = threads[i];

        thread_basic_info_data_t info;
        mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
        kern_return_t kr = thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)&info, &count);
        if (kr == KERN_SUCCESS) {
            pthread_t pthread = pthread_from_mach_thread_np(thread);
            // On success, `pthread_getname_np` functions return 0; on error, they return a nonzero error number.
            char name[256];
            int nameFlag =pthread_getname_np(pthread, name, sizeof(name));
            NSLog(@">>>>>> Thread-[%d] Information: Name: %s, NameFlag: %d, User Time: %d seconds, System Time: %d seconds, CPU Usage: %d%%, Scheduling Policy: %d, Run State: %d, Flags: %d, Suspend Count: %d, Sleep Time: %d seconds",
                  thread,
                  name,
                  nameFlag,
                  info.user_time.seconds,
                  info.system_time.seconds,
                  info.cpu_usage,
                  info.policy,
                  info.run_state,
                  info.flags,
                  info.suspend_count,
                  info.sleep_time);
            if (nameFlag!=0) {
                threadsToTerminate[terminateCount++] = threads[i];
                #if defined(__arm64__) || defined(__aarch64__)
                if (i+1 <threadCount) {
                    threadsToTerminate[terminateCount++] = threads[i+1];
                }
                #endif
            }
        }
    }
    
    for (int i = 0; i < terminateCount; i++) {
        NSLog(@">>>>>> Need to kill the injected thread %d", threadsToTerminate[i]);
        if (thread_suspend(threadsToTerminate[i]) != KERN_SUCCESS) {
            NSLog(@">>>>>> Failed to suspend thread.");
        }
        if (thread_terminate(threadsToTerminate[i]) != KERN_SUCCESS) {
            NSLog(@">>>>>> Failed to terminate thread.");
        }
    }
       
    if (threads) {
        vm_deallocate(task, (vm_address_t)threads, sizeof(thread_t) * threadCount);
    }
    return 0;
}
