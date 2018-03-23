//
//  ViewController.m
//  DCDBHandler
//
//  Created by chun.chen on 2018/3/23.
//  Copyright © 2018年 cc. All rights reserved.
//

#import "ViewController.h"
#import "DCDBHandler.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    NSMutableArray *mArr = @[].mutableCopy;
    for (NSInteger i = 0; i < 10; i++) {
        User *user = [[User alloc] init];
        user.userId = @(i);
        user.name = [NSString stringWithFormat:@"name_%@",@(i)];
        user.avatar = [NSString stringWithFormat:@"avatar_%@",@(i)];
        user.age = arc4random() % 100;
        [mArr addObject:user];
    }
    
    [[DCDBHandler sharedInstance] insertOrUpdateWithModelArr:mArr byPrimaryKey:@"userId"];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (NSInteger i = 0; i < 10; i++) {
            NSArray *user = [[DCDBHandler sharedInstance] queryWithClass:[User class] key:@"userId" value:@(i) orderByKey:nil desc:YES];
            NSLog(@"result ( %@ )",[user lastObject]);
        }
    });
}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end


@implementation User

- (NSString *)description {
    return [NSString stringWithFormat:@"userId = %@\n name= %@\n avatar=%@\n age=%@",self.userId,self.name,self.avatar,@(self.age)];
}

@end

