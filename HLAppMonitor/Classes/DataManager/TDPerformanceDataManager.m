//
//  TDPerformanceDataManager.m
//  TuanDaiV4
//
//  Created by guoxiaoliang on 2018/6/28.
//  Copyright © 2018 Dee. All rights reserved.
//性能获取数据管理者

#import "TDPerformanceDataManager.h"
#import "TDPerformanceDataModel.h"
#import "TDGlobalTimer.h"
#import "TDDispatchAsync.h"
#import "TDPerformanceMonitor.h"
#import "TDFPSMonitor.h"
#import <HLAppMonitor/HLAppMonitor-Swift.h>
#import <mach/mach.h>
#import <mach/task_info.h>
#import "TDNetworkTrafficManager.h"
#import <objc/runtime.h>
#import "SignalHandler.h"
#import "UncaughtExceptionHandler.h"
//#import "性能测试/Network/TDNetFlowDataSource.h"
@interface TDPerformanceDataManager () <LeakEyeDelegate,CrashEyeDelegate,ANREyeDelegate,TDFPSMonitorDelegate>
{
    LeakEye *leakEye;
    ANREye *anrEye;
    //开始时间
    long long startTime;
    //app启动时间
    NSTimeInterval appStartupTime;
    //信号量
    dispatch_semaphore_t semaphore;
    //锁 数据安全
    NSCondition * condition;

}
//是否开始监控
@property(nonatomic,assign)BOOL isStartMonitor;
//是否正在监控
@property(nonatomic,assign)BOOL isMonitoring;
//是否开始缓存
@property(nonatomic,assign)BOOL isStartCasch;
//是否开启基本性能监控
@property(nonatomic,assign)BOOL isStartBaseMonitor;
//是否开始帧率监控
@property(nonatomic,assign)BOOL isStartFPSMonitor;
//是否开始网络监控
@property(nonatomic,assign)BOOL isStartNetworkMonitor;
//是否开启卡顿监控
@property(nonatomic,assign)BOOL isStartCatonMonitor;
//是开启崩溃监控
@property(nonatomic,assign)BOOL isStartCrashMonitor;
//基本性能数据定时器间隔
@property(nonatomic,assign)NSInteger basicTime;
//上传文件的间隔
//@property(nonatomic,assign)NSInteger intervaTime;
//是否正在写入数据
@property(nonatomic,assign)BOOL isWrite;

@end
static uint64_t loadTime;
static uint64_t applicationRespondedTime = -1;
static mach_timebase_info_data_t timebaseInfo;
static inline NSTimeInterval MachTimeToSeconds(uint64_t machTime) {
    return ((machTime / 1e9) * timebaseInfo.numer) / timebaseInfo.denom;
}
static long long logNum = 1;

@implementation TDPerformanceDataManager
//写入沙盒队列(消费者模式队列)
static inline dispatch_queue_t td_log_IO_queue() {
    static dispatch_queue_t td_log_IO_queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        td_log_IO_queue = dispatch_queue_create("com.tuandaiguo.td_log_IO_queue", NULL);
    });
    return td_log_IO_queue;
}
//写入内存的队列(生产者模式队列)
static inline dispatch_queue_t td_log_IO_Producequeue() {
    static dispatch_queue_t td_log_IO_Producequeue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        td_log_IO_Producequeue = dispatch_queue_create("com.tuandaiguo.td_log_IO_Producequeue", NULL);
    });
    return td_log_IO_Producequeue;
}
/*
 因为类的+ load方法在main函数执行之前调用，所以我们可以在+ load方法记录开始时间，同时监听UIApplicationDidFinishLaunchingNotification通知，收到通知时将时间相减作为应用启动时间，这样做有一个好处，不需要侵入到业务方的main函数去记录开始时间点。
 */
+ (void)load {
    loadTime = mach_absolute_time();
    mach_timebase_info(&timebaseInfo);
    @autoreleasepool {
        __block id obs;
        obs = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                                object:nil queue:nil
                                                            usingBlock:^(NSNotification *note) {
                                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                                    
                                                                    applicationRespondedTime = mach_absolute_time();
                                                                    NSString *appStartupTime =  [[TDPerformanceDataManager sharedInstance] getStringAppStartupTime:MachTimeToSeconds(applicationRespondedTime - loadTime)];
                                                                    [[TDPerformanceDataManager sharedInstance] normalDataStrAppendwith:appStartupTime];
                                                                });
                                                                [[NSNotificationCenter defaultCenter] removeObserver:obs];
                                                            }];
    }
}
+ (instancetype)sharedInstance
{
    static TDPerformanceDataManager * instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TDPerformanceDataManager alloc] init];
    });
    return instance;
}
- (instancetype)init
{
    self = [super init];
    if (self) {
        //创建信号量
        semaphore = dispatch_semaphore_create(0);
        //锁 同步数据
        condition = [[NSCondition alloc]init];
    }
    return self;
}

#pragma mark - Private
// 命令行会改这个值
static NSString *customFilePath = @"filePath";
- (NSString *)createFilePath {
    if ([customFilePath isEqualToString:pathFlag]) {
        static NSString * const kLoggerDatabaseFileName = @"app_logger";
        NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).lastObject stringByAppendingPathComponent: kLoggerDatabaseFileName];
        NSFileManager * manager = [NSFileManager defaultManager];
        if (![manager fileExistsAtPath: path]) {
            [manager createDirectoryAtPath: path withIntermediateDirectories: YES attributes: nil error: nil];
            NSLog(@"path=%@",path);
        }
        return path;
    }else {
        return customFilePath;
    }
}

static NSString * td_resource_recordDataIntervalTime_callback_key;

//开启监控总开关
- (void)setIsStartMonitor:(BOOL)isStartMonitor {
    _isStartMonitor = isStartMonitor;
    if (isStartMonitor) {
        //开始监控
        [self startPerformanceRecordWithBasicTime:self.basicTime];
    }else{
        [self stopAppPerformanceMonitor];
    }
}
//基本性能数据
- (void)setIsStartBaseMonitor:(BOOL)isStartBaseMonitor {
    
    _isStartBaseMonitor = isStartBaseMonitor;
    if (isStartBaseMonitor) {
        self.isStartCasch = YES;
        if (self.basicTime > 0) {
             [self startBasicResourceDataTime: self.basicTime];
        }else{
             [self startBasicResourceDataTime: 1];
        }
    }else{
        [self stopResourceData];
    }
}
//帧率fps
- (void)setIsStartFPSMonitor:(BOOL)isStartFPSMonitor {
    
    _isStartFPSMonitor = isStartFPSMonitor;
    if (isStartFPSMonitor) {
        self.isStartCasch = YES;
        //开启fps监控
        [[TDFPSMonitor sharedMonitor]startMonitoring];
        //开启fps检测
        [TDFPSMonitor sharedMonitor].delegate = self;
    }else{
        //开启fps监控
        [[TDFPSMonitor sharedMonitor]stopMonitoring];
        //开启fps检测
        [TDFPSMonitor sharedMonitor].delegate = nil;
    }
}
//网络
- (void)setIsStartNetworkMonitor:(BOOL)isStartNetworkMonitor {
    
    _isStartNetworkMonitor = isStartNetworkMonitor;
    if (isStartNetworkMonitor) {
        self.isStartCasch = YES;
        //开启网络流量监控
        //开启网络监控
        [TDNetworkTrafficManager start];
    }else{
        //暂停网络流量监控
        //暂停网络监控
        [TDNetworkTrafficManager end];
    }
}
//卡顿
- (void)setIsStartCatonMonitor:(BOOL)isStartCatonMonitor {
    
    _isStartCatonMonitor = isStartCatonMonitor;
    if (isStartCatonMonitor) {
        self.isStartCasch = YES;
        if (self->anrEye == nil) {
             self->anrEye = [[ANREye alloc] init];
        }
        //开启anrEye
        self->anrEye.delegate = self;
        [self->anrEye openWith:0.2];
    }else{
        if (self ->anrEye) {
            self->anrEye.delegate = nil;
            [self->anrEye close];
        }
    }
}
//崩溃
- (void)setIsStartCrashMonitor:(BOOL)isStartCrashMonitor {
    
    _isStartCrashMonitor = isStartCrashMonitor;
    if (isStartCrashMonitor) {
        self.isStartCasch = YES;
        //开启奔溃检测
        [CrashEye addWithDelegate:self];
    }else{
        //移除奔溃检测
        [CrashEye removeWithDelegate:self];
    }
}

//改变监控指标状态 Indicators:监控指标,isStartMonitor:监控是否开启与关闭
- (void)didChangeMonitoringIndicators: (TDMonitoringIndicators)Indicators withChangeStatus:(BOOL)isStartMonitor {
    
    switch (Indicators) {
        case _TDMonitoringIndicatorsALL://所有的
            self.isStartMonitor = isStartMonitor;
            break;
        case _TDMonitoringIndicatorsBase://基本性能数据
            self.isStartBaseMonitor = isStartMonitor;
            break;
        case _TDMonitoringIndicatorsFPS://帧率FPS
            self.isStartFPSMonitor = isStartMonitor;
            break;
        case _TDMonitoringIndicatorsNetwork://网络
            self.isStartNetworkMonitor = isStartMonitor;
            break;
        case _TDMonitoringIndicatorsCaton://卡顿
            self.isStartCatonMonitor = isStartMonitor;
            break;
        case _TDMonitoringIndicatorsCrash://崩溃
            self.isStartCrashMonitor = isStartMonitor;
            break;
        default:
            break;
    }
}
/**
 开始性能监控,
 @param basicTime 基本性能数据获取间隔时间
 */
- (void)startPerformanceRecordWithBasicTime:(NSInteger)basicTime {
     //如果有监控 就不用往下走了
    if (self.isMonitoring) {//如果正在监控  就不用了
        return;
    }
    self.isMonitoring = YES;
   //开启监控
    if (!self.isStartMonitor) {//是否开始监控
        return;
    }
    //记录基本性能数据定时器间隔
    if (basicTime > 0) {
        self.basicTime = basicTime;
    }else{
        self.basicTime = 1;
    }
    //开始缓存机制
    self.isStartCasch = YES;
    //记录开始时间
    self ->startTime = [self currentTime];
    //获取APP基本性能数据
    [self getAppBaseInfo];
    //开启基本性能数据 //基本性能数据获取定时器 
    self.isStartBaseMonitor = YES;
    //开启帧率FPS监控
    self.isStartFPSMonitor = YES;
    //网络 开启网络流量监控
    self.isStartNetworkMonitor = YES;
    //卡顿//开启anrEye
    self.isStartCatonMonitor = YES;
    //崩溃开启奔溃检测
    self.isStartCrashMonitor = YES;
    //开始监控写入沙盒数据
    [self writePerformanceDadaToDisk];
}
//写入沙盒性能数据
- (void)writePerformanceDadaToDisk {
    //是否开始写入
    if (self.isWrite) {//开始写入 就返回 保证就一次调用这里
        return;
    }
    self.isWrite = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(td_log_IO_queue(), ^{//消费者模式
        
        while (1) {
            //等待通知  等待唤醒
            dispatch_semaphore_wait(self ->semaphore,DISPATCH_TIME_FOREVER);
            //锁住
            [self ->condition lock];
            //写入沙盒中
            NSData *normalData = [weakSelf.normalDataStr dataUsingEncoding:NSUTF8StringEncoding];
            [weakSelf writeToFileWith:normalData];
            //解锁
            [self ->condition unlock];
        }
        
    });
}
//定时将数据字符串写入沙盒文件 兼容之前写main分支代码
- (void)startToCollectPerformanceData {
    //默认数据设置60s上传文件间隔,1s获取基本性能数据间隔
    //设置基本性能数据间隔
    self.basicTime = 1;
    self.isStartMonitor = YES;
    
}
// 文件写入操作
- (void)writeToFileWith:(NSData *)data {
    NSString *path = [self createFilePath];
    NSString *fileDicPath = [path stringByAppendingPathComponent:@"appLogIOS.txt"];
    // 4.创建文件对接对象
    NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:fileDicPath];
    if (handle == nil) {
         [[NSData new] writeToFile:fileDicPath atomically:YES];
         handle = [NSFileHandle fileHandleForUpdatingAtPath:fileDicPath];
    }
    //找到并定位到outFile的末尾位置(在此后追加文件)
    [handle seekToEndOfFile];
    [handle writeData:data];
    //关闭读写文件
    [handle closeFile];
    [self clearCache];
}
//结束写入数据
- (void)endWriteData {
    
    if (!self.normalDataStr || [self.normalDataStr isEqualToString:@""]) {//如果为空值 或者为nil 就不做此操作
        return;
    }
    //下面就一定有值
      __weak typeof(self) weakSelf = self;
    dispatch_async(td_log_IO_queue(), ^{
        //将String写入文件
        //结束时间
        long long curt = [self currentTime];
        NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
        [weakSelf getStringResourceDataTime:currntime withStartOrEndTime:currntime withIsStartTime:NO];
        NSData *normalData = [weakSelf.normalDataStr dataUsingEncoding:NSUTF8StringEncoding];
        [weakSelf writeToFileWith:normalData];
        
    });
}
//拼接数据
- (void)normalDataStrAppendwith:(NSString*)str {
    __weak typeof(self) weakSelf = self;
    dispatch_async(td_log_IO_Producequeue(), ^{//生产者队列
        
        if (str) {
            //锁住
            [self ->condition lock];
            //拼接数据
            [weakSelf.normalDataStr appendString:str];
            //结束时间
            long long curt = [self currentTime];
            NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
            [weakSelf getStringResourceDataTime:currntime withStartOrEndTime:currntime withIsStartTime:NO];
            //解锁
            [self ->condition unlock];
            //通知 唤醒写入数据
            dispatch_semaphore_signal(self ->semaphore);
        }
        
    });
}

//logNum加1
- (void)logNumAddOne {
    logNum += 1;
}
//清空txt文件
- (void)clearTxt {
    logNum = 1;
    NSString * path = [self createFilePath];
    NSString *fileDicPath = [path stringByAppendingPathComponent:@"appLogIOS.txt"];
    NSFileManager * manager = [NSFileManager defaultManager];
    BOOL isExistence = [manager fileExistsAtPath:fileDicPath];
    if (isExistence) {
        NSError * error ;
        BOOL isRemove = [manager removeItemAtPath:fileDicPath error:&error];
        if (isRemove) {
            NSLog(@"%@",@"删除成功");
        }else{
            NSLog(@"删除失败--error:%@",error);
        }
    }else{
        NSLog(@"文件不存在，请确认路径");
    }
    //写入基本数据
    [self getAppBaseInfo];
}
//清空缓存
- (void)clearCache {
    self.normalDataStr = [[NSMutableString alloc] initWithString:@""];
    //清空流量
  //  [[TDNetFlowDataSource shareInstance] clear];
}
//获取app基本信息数据
- (void)getAppBaseInfo {
    // 获取CPU架构
    NSString * cpu = [TDPerformanceMonitor getCPUFramwork];
    if (!cpu || [cpu isKindOfClass:[NSNull class]] || cpu == NULL || !cpu.length) {
        cpu = @"Unkonwn";
    }
    //app Bundel ID
    NSString * bundelID = [TDPerformanceMonitor appBundleIdentifier];
    //app 版本号
    NSString * versionName = [TDPerformanceMonitor appVersion];
    //app 构建版本号
    NSString * appVersion = [TDPerformanceMonitor appBuildVersion];
    // app name
    NSString * appName = [TDPerformanceMonitor appName];
    //设备Id
    NSString * deviceId = [TDPerformanceMonitor deviceId];
    //手机型号
    NSString * deviceModel = [TDPerformanceMonitor deviceModel];
    //系统版本
    NSString * deviceVersion = [TDPerformanceMonitor systemVersion];
    //开始监控时间传给gt,一开始取出时间
    NSString *currntime = [NSString stringWithFormat:@"%lld",self ->startTime];
    // 1,时间 2,bundelID 3,appName,4,app 版本号,5系统版本 6,手机型号 7 app 构建版本号 8,设备Id 9 cpu
    NSString * appInfo = [self getStringAppBaseDataTime:currntime withBundleId:bundelID withAppName:appName withAppVersion:versionName withDeviceVersion:deviceVersion withDeviceName:deviceModel withVersionName:appVersion withDeviceId:deviceId withCpu:cpu];
    [self normalDataStrAppendwith:appInfo];
}

//获取app基本性能数据
static NSString * td_resource_monitorData_callback_key;
- (void)startBasicResourceDataTime:(NSInteger)intervaTime {
    if (!self.isStartBaseMonitor) {
        return;
    }
    if (td_resource_monitorData_callback_key != nil) { return; }
    
    //设置定时器间隔
    [TDGlobalTimer setCallbackInterval:intervaTime];
  __weak typeof(self) weakSelf = self;
    
    td_resource_monitorData_callback_key = [[TDGlobalTimer registerTimerCallback: ^{
        NSString *currntime = [self getCurrntTime];
        //fps
        double fps = [[TDFPSMonitor sharedMonitor] getFPS];
        NSString *fpsStr = [NSString stringWithFormat:@"%d",(int)fps];
        //内存,当前任务使用内存
        double appRam = [[Memory applicationUsage][0] doubleValue];
        NSString *appRamStr = [NSString stringWithFormat:@"%f",appRam];
        double activeRam = [[Memory systemUsage][1] doubleValue];
        double inactiveRam = [[Memory systemUsage][2] doubleValue];
        double wiredRam = [[Memory systemUsage][3] doubleValue];
        double totleSysRam = [[Memory systemUsage][5] doubleValue];
        //使用内存 含100%
        double sysRamPercent = ((activeRam + inactiveRam + wiredRam)/totleSysRam) *100;
        NSString *sysRamPercentStr = [NSString stringWithFormat:@"%.1f",sysRamPercent];
        //CPU
        double appCpu = [CPU applicationUsage];
       // float appCpu1 =  [[TDPerformanceMonitor sharedInstance] getCpuUsage];
       // NSString *appCpuS = [NSString stringWithFormat:@"%.1f",appCpu1];
        NSString *appCpuStr = [NSString stringWithFormat:@"%.1f",appCpu];
        NSString *sysCpu = [CPU systemUsage][0];
        NSString *userCpu = [CPU systemUsage][1];
        NSString *niceCpu = [CPU systemUsage][3] ;
        double systemCpu = sysCpu.doubleValue + userCpu.doubleValue + niceCpu.doubleValue;
        NSString *systemCpuStr = [NSString stringWithFormat:@"%.1f",systemCpu];
      
        NSString *normS = [weakSelf getStringResourceDataTime:currntime withFPS:fpsStr withAppRam:appRamStr withSysRam:sysRamPercentStr withAppCpu:appCpuStr withSysCpu:systemCpuStr];
        [self normalDataStrAppendwith:normS];
    }] copy];
}
//停止监控基本数据获取
- (void)stopResourceData {
    //[self clearCache];
    if (td_resource_monitorData_callback_key == nil) { return; }
    [TDGlobalTimer resignTimerCallbackWithKey: td_resource_monitorData_callback_key];
    td_resource_monitorData_callback_key = NULL;
}
//停止写入监控性能数据
- (void)stopUploadResourceData {
    if (!self.isMonitoring) {//表示并没有监控  
        return;
    }
    self.isMonitoring = NO;
    if (self.isStartMonitor) {
        return;
    }
    self.isStartCasch = NO;
    if (td_resource_monitorData_callback_key == nil) { return; }
    [TDGlobalTimer resignTimerCallbackWithKey: td_resource_monitorData_callback_key];
    td_resource_monitorData_callback_key = NULL;
}
//停止监控性能
- (void)stopAppPerformanceMonitor {
    [self stopUploadResourceData];
    //暂停基本性能数据监控
    self.isStartBaseMonitor = NO;
    //暂停fps数据监控
    self.isStartFPSMonitor = NO;
    //暂停网络监控
    self.isStartNetworkMonitor = NO;
    //暂停卡顿监控
    self.isStartCatonMonitor = NO;
    //暂停崩溃监控
    self.isStartCrashMonitor = NO;
}

////拼接开始或结束时间 startEndTime: 开始或结束时间 ,isStartTime是否开始还是结束时间
- (void)getStringResourceDataTime:(NSString *)currntTime withStartOrEndTime:(NSString *)startEndTime withIsStartTime:(BOOL) isStartTime {
    if (!self.isStartCasch) {//有需要缓存才缓存
        return;
    }
    if (isStartTime) {
        //将开始时间拼接在这里
        NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%lld^%@^startResourceDataTime", logNum,currntTime];
        @synchronized (self) {
            [self logNumAddOne];
            [att appendFormat:@"^%@",startEndTime]; //开始时间
            [att appendFormat:@"^%@",@"\n"];
        }
         //[self normalDataStrAppendwith:att];
        [self.normalDataStr appendString:att];
    }else{
        //将结束时间拼接在这里
        NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%lld^%@^stopResourceDataTime", logNum,currntTime];
        @synchronized (self) {
            [self logNumAddOne];
            [att appendFormat:@"^%@",startEndTime]; //开始时间
            [att appendFormat:@"^%@",@"\n"];
        }
        // [self normalDataStrAppendwith:att];
         [self.normalDataStr appendString:att];
    }
}
//异步获取数据,生命周期方法名
- (void)asyncExecuteClassName:(NSString *)className withStartTime:(NSString *)startTime withEndTime:(NSString *)endTime withHookMethod:(NSString *)hookMethod withUniqueIdentifier:(NSString *)uniqueIdentifier {
    if (!self.isStartCasch) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self asyncExecute:^{
        NSString *currntime = [self getCurrntTime];
        NSString *hookS = [weakSelf getStringExecuteTime:currntime withClassName:className withStartTime:startTime withEndTime:endTime withHookMethod:hookMethod  withUniqueIdentifier: uniqueIdentifier];
        [weakSelf normalDataStrAppendwith:hookS];
    }];
}
//app基本性能数据   //1,当前时间,2,fps  3,当前任务使用内存,4,使用内存,5,当前使用CPU,6 使用cpu
- (NSString *)getStringResourceDataTime:(NSString *)currntTime withFPS:(NSString *)fps withAppRam:(NSString *)appRam withSysRam:(NSString *)sysRam withAppCpu:(NSString *)appCpu withSysCpu:(NSString *)sysCpu {
    if (!self.isStartCasch) {
        return nil;
    }
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%lld^%@^normalCollect", logNum,currntTime];
    @synchronized (self) {
        [self logNumAddOne];
        [att appendFormat:@"^%@",appCpu]; //百分比  当前使用CPU
        [att appendFormat:@"^%@",sysCpu]; //百分比  使用cpu
        [att appendFormat:@"^%@",appRam]; //Byte  当前任务使用内存
        [att appendFormat:@"^%@",sysRam]; //百分比 使用内存
        long long uploadFlow = [TDNetFlowDataSource shareInstance].uploadFlow;
        long long downFlow = [TDNetFlowDataSource shareInstance].downFlow;
        [att appendFormat:@"^%lld",uploadFlow];//上行流量
        [att appendFormat:@"^%lld",downFlow]; //下行流量
        [att appendFormat:@"^%@",@"\n"];
       
    }
    return att.copy;
    
}
//app基本信息数据/// 1,时间 2,bundelID 3,appName,4,app 版本号,5系统版本 6,手机型号 7 app 构建版本号 8,设备Id 9 cpu
- (NSString *)getStringAppBaseDataTime:(NSString *)currntTime withBundleId:(NSString *)bunldID
                           withAppName:(NSString *)appName withAppVersion:(NSString *)appVersion
                     withDeviceVersion:(NSString *)deviceVersion withDeviceName:(NSString *)deviceName withVersionName:(NSString *)versionName withDeviceId:(NSString *)deviceId withCpu:(NSString *)cpu{
    if (!self.isStartCasch) {
        return nil;
    }
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%lld^%@^appCollect", logNum,currntTime];
    
    @synchronized (self) {
        [self logNumAddOne];
        [att appendFormat:@"^%@",bunldID];//bunldID
        [att appendFormat:@"^%@",appName];//项目名4appName
        [att appendFormat:@"^%@",appVersion];//版本号
        [att appendFormat:@"^%@",deviceVersion];// 系统版本
        [att appendFormat:@"^%@",deviceName];//手机型号
        [att appendFormat:@"^%@",versionName];//app 构建版本号
        [att appendFormat:@"^%@",deviceId];// 设备Id
        [att appendFormat:@"^%@",cpu];//cpu
        [att appendFormat:@"^%@",@"\n"];
    }
    return att.copy;
    
}
//app启动时间
- (NSString *)getStringAppStartupTime:(NSTimeInterval)appStartupTime {
    if (!self.isStartCasch) {
        return nil;
    }
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%lld^1000^appStartupTime", logNum];
    @synchronized (self) {
        [self logNumAddOne];
        NSString *startupTimeS = [NSString stringWithFormat:@"%f",appStartupTime];
        [att appendFormat:@"^%@",startupTimeS];
        [att appendFormat:@"^%@",@"\n"];
    }
    return att.copy;
}
//页面生命周期方法,uniqueIdentifier:页面唯一标识
- (NSString *)getStringExecuteTime:(NSString *)currntTime withClassName:(NSString *)className withStartTime:(NSString *)startTime withEndTime:(NSString *)endTime withHookMethod:(NSString *)hookMethod withUniqueIdentifier:(NSString *)uniqueIdentifier{
    if (!self.isStartCasch) {
        return nil;
    }
    NSMutableString *hookSt = [[NSMutableString alloc]initWithFormat:@"%lld^%@^%@", logNum,currntTime,hookMethod];
    @synchronized (self) {
        [self logNumAddOne];
        [hookSt appendFormat:@"^%@",className];
        [hookSt appendFormat:@"^%@",uniqueIdentifier];
        [hookSt appendFormat:@"^%@",startTime];
        [hookSt appendFormat:@"^%@",endTime];
        [hookSt appendFormat:@"^%@",@"\n"];
        //NSLog(@"%@",hookSt);
    }
    return hookSt.copy;
}
//页面渲染时间
- (NSString *)getRenderWithClassName:(NSString *)className withRenderTime:(NSString *)renderTime {
    long long curt = [self currentTime];
    NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
    NSMutableString *renderStr = [[NSMutableString alloc]initWithFormat:@"%lld^%@^renderCollect", logNum,currntime];
    @synchronized (self) {
        [self logNumAddOne];
        [renderStr appendFormat:@"^%@",className];
        [renderStr appendFormat:@"^%@",renderTime];
        [renderStr appendFormat:@"^%@",@"\n"];
    }
    return renderStr.copy;
}
- (void)asyncExecute: (dispatch_block_t)block {
    assert(block != nil);
    if ([NSThread isMainThread]) {
        TDDispatchQueueAsyncBlockInUtility(block);
    } else {
        block();
    }
}
- (NSMutableString *)normalDataStr {
    if (_normalDataStr) {
        return _normalDataStr;
    }
    _normalDataStr = [[NSMutableString alloc] init];
    return _normalDataStr;
}
#pragma mark - GodEyeDelegate
//检测到内存泄漏
-(void)leakEye:(LeakEye *)leakEye didCatchLeak:(NSObject *)object
{
    if (!self.isStartCasch) {
        return;
    }
    long long curt = [self currentTime];
    NSString *currntTime = [NSString stringWithFormat:@"%lld",curt];
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%lld^%@^leakCollect",logNum,currntTime];
    @synchronized (self) {
        [self logNumAddOne];
        [att appendFormat:@"^%@",NSStringFromClass(object.classForCoder)];
        [att appendFormat:@"^%@",object];
        [att appendFormat:@"^%@",@"\n"];
    }
    [self normalDataStrAppendwith:att];
}

//检测到crash
- (void)crashEyeDidCatchCrashWith:(CrashModel *)model
{
    if (!self.isStartCasch) {
        return;
    }
    NSString *str = [self getCrashInfoWithModel:model];
    //直接写入沙盒去,不能切换线程
    //  [self normalDataStrAppendwith:str];
    if (str) {
        [self.normalDataStr appendString:str];
    }
    NSString *currntime = [self getCurrntTime];
    [self getStringResourceDataTime:currntime withStartOrEndTime:currntime withIsStartTime:NO];
    NSData *normalData = [self.normalDataStr dataUsingEncoding:NSUTF8StringEncoding];
    [self writeToFileWith:normalData];
}

//app的crash数据
- (NSString *)getCrashInfoWithModel:(CrashModel *)model {
    
    NSString *type = model.type;
    NSString *name = model.name;
    NSString *reason = model.reason;//[model.reason stringByReplacingOccurrencesOfString:@"\n" withString:@"#&####"];//
    //NSString *appinfo = model.appinfo;//[model.appinfo stringByReplacingOccurrencesOfString:@"\n" withString:@"#&####"];//model.appinfo;
    NSString *callStack = [model.callStack stringByReplacingOccurrencesOfString:@"\r" withString:@"#&####"];//model.callStack;
    //  NSLog(@"type=%@--name=%@--reason=%@--appinfo=%@--callStack=%@",type,name,reason,appinfo,callStack);
    NSString *currntTime = [self getCurrntTime];
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%lld^%@^CrashCollect", logNum,currntTime];
    @synchronized (self) {
        [self logNumAddOne];
        [att appendFormat:@"^%@",type];
        [att appendFormat:@"^%@",name];
        [att appendFormat:@"^%@",reason];
        [att appendFormat:@"^%@",callStack];
        [att appendFormat:@"^%@",@"\n"];
    }
    return att.copy;
    
}

//检测到卡顿
- (void)anrEyeWithAnrEye:(ANREye *)anrEye startTime:(int64_t)startTime endTime:(int64_t)endTime catchWithThreshold:(double)threshold mainThreadBacktraceList:(NSArray<NSDictionary<NSString *,NSString *> *> *)mainThreadBacktraceList{
    if (!self.isStartCasch) {
        return;
    }
    //NSLog(@"INRCollectMainThreadStackInformation=---%@",mainThreadBacktraceList);
    NSMutableString *attStatickList = [[NSMutableString alloc]init];
    @synchronized (self) {
        for (NSDictionary<NSString *,NSString *> *stackInformation in mainThreadBacktraceList) {
            NSMutableString *attStatick = [[NSMutableString alloc]initWithFormat:@"%ld^%@^INRCollectMainThreadStackInformation", (long)logNum,@"100000"];
              [self logNumAddOne];
            NSString *start = stackInformation[@"startTime"];
            NSString *stackI = stackInformation[@"stackInformation"];
            //开始时间
            [attStatick appendFormat:@"^%@",start];
             [attStatick appendFormat:@"^%@",stackI];
             [attStatick appendFormat:@"^%@",@"\n"];
            [attStatickList appendString:attStatick];
        }
    }
    [self normalDataStrAppendwith:attStatickList];
    NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%ld^%@^INRCollectMainThread", (long)logNum,[self getCurrntTime]];
    @synchronized (self) {
        [self logNumAddOne];
        //开始时间
        [att appendFormat:@"^%lld",startTime];
        //结束时间
        [att appendFormat:@"^%lld",endTime];
        //卡顿时长
        [att appendFormat:@"^%lld",endTime - startTime];
        //[att appendFormat:@"^%@",mainThreadBacktraceList];
        [att appendFormat:@"^%@",@"\n"];
    }
    [self normalDataStrAppendwith:att];
}
#pragma mark - TDFPSMonitorDelegate
//获取帧率时间
- (void)fpsFrameCurrentTime:(NSString *)currentTime {
    
    __weak typeof(self) weakSelf = self;
    [self asyncExecute:^{
        long long curt = [self currentTime];
        NSString *currntime = [NSString stringWithFormat:@"%lld",curt];
        NSMutableString *att = [[NSMutableString alloc]initWithFormat:@"%lld^%@^FPSCollect", logNum,currntime];
        @synchronized (self) {
            [self logNumAddOne];
            //获取时间
            [att appendFormat:@"^%@",currentTime];
            [att appendFormat:@"^%@",@"\n"];
        }
        [weakSelf normalDataStrAppendwith:att];
    }];
}
- (NSString *)getCurrntTime {
    long long curt = [self currentTime];
    NSString *currntTime = [NSString stringWithFormat:@"%lld",curt];
    return currntTime;
}
//获取当前时间
- (long long)currentTime {
    NSTimeInterval time = [[NSDate date] timeIntervalSince1970] * 1000;
    long long dTime = [[NSNumber numberWithDouble:time] longLongValue]; 
    return dTime;
}

@end
