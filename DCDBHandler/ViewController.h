//
//  ViewController.h
//  DCDBHandler
//
//  Created by chun.chen on 2018/3/23.
//  Copyright © 2018年 cc. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface ViewController : UIViewController


@end


@interface User : NSObject

@property (nonatomic, strong) NSNumber *userId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *avatar;
@property (nonatomic, assign) NSInteger age;

@end

