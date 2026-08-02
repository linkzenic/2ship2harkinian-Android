#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>

#include <SDL.h>
#include <algorithm>
#include <atomic>
#include <cmath>

#include "TwoShipIOSTouchControls.h"

namespace {

constexpr int kButtonA = 0;
constexpr int kButtonB = 1;
constexpr int kButtonX = 2;
constexpr int kButtonY = 3;
constexpr int kButtonBack = 4;
constexpr int kButtonStart = 6;
constexpr int kButtonLeftShoulder = 9;
constexpr int kButtonRightShoulder = 10;
constexpr int kButtonDpadUp = 11;
constexpr int kButtonDpadDown = 12;
constexpr int kButtonDpadLeft = 13;
constexpr int kButtonDpadRight = 14;

constexpr int kAxisLeftX = 0;
constexpr int kAxisLeftY = 1;
constexpr int kAxisRightX = 2;
constexpr int kAxisRightY = 3;
constexpr int kAxisLeftTrigger = 4;
constexpr int kAxisRightTrigger = 5;

SDL_Joystick* sJoystick = nullptr;
int sJoystickIndex = -1;
std::atomic_bool sMenuToggleRequested(false);
std::atomic_bool sMenuVisible(false);
std::atomic_uint16_t sTouchButtons(0);
std::atomic_uint16_t sPendingTouchButtons(0);
std::atomic_int sTouchLeftX(0);
std::atomic_int sTouchLeftY(0);
std::atomic_int sTouchRightX(0);
std::atomic_int sTouchRightY(0);
std::atomic_int sPendingTouchLeftX(0);
std::atomic_int sPendingTouchLeftY(0);
std::atomic_int sPendingTouchRightX(0);
std::atomic_int sPendingTouchRightY(0);
CMMotionManager* sDeviceMotionManager = nil;

uint16_t N64ButtonForSDLButton(int button) {
    switch (button) {
        case kButtonA:
            return 0x8000;
        case kButtonB:
            return 0x4000;
        case kButtonX:
            return 0x0008; // C-Up
        case kButtonY:
            return 0x0002; // C-Left
        case kButtonStart:
            return 0x1000;
        case kButtonLeftShoulder:
            return 0x0020;
        case kButtonRightShoulder:
            return 0x0010;
        case kButtonDpadUp:
            return 0x0800;
        case kButtonDpadDown:
            return 0x0400;
        case kButtonDpadLeft:
            return 0x0200;
        case kButtonDpadRight:
            return 0x0100;
        default:
            return 0;
    }
}

void SetDirectButton(uint16_t mask, bool pressed) {
    if (mask == 0) {
        return;
    }
    if (pressed) {
        sTouchButtons.fetch_or(mask);
        // Preserve quick taps until the 20 Hz game input poll consumes them.
        sPendingTouchButtons.fetch_or(mask);
    } else {
        sTouchButtons.fetch_and(static_cast<uint16_t>(~mask));
    }
}

UIColor* ControlFill() {
    return [UIColor colorWithWhite:1.0 alpha:0.14];
}

UIColor* ControlStroke() {
    return [UIColor colorWithWhite:1.0 alpha:0.30];
}

bool EnsureController() {
    if (sJoystick != nullptr) {
        if (SDL_JoystickGetAttached(sJoystick) == SDL_TRUE) {
            return true;
        }
        SDL_JoystickClose(sJoystick);
        sJoystick = nullptr;
        sJoystickIndex = -1;
    }
    const Uint32 requiredSubsystems = SDL_INIT_JOYSTICK | SDL_INIT_GAMECONTROLLER;
    if ((SDL_WasInit(requiredSubsystems) & requiredSubsystems) != requiredSubsystems &&
        SDL_InitSubSystem(requiredSubsystems) < 0) {
        SDL_Log("Could not initialize 2Ship iOS touch input: %s", SDL_GetError());
        return false;
    }
    sJoystickIndex = SDL_JoystickAttachVirtual(SDL_JOYSTICK_TYPE_GAMECONTROLLER, 6, 18, 0);
    if (sJoystickIndex < 0) {
        SDL_Log("Could not attach 2Ship iOS touch controller: %s", SDL_GetError());
        return false;
    }

    SDL_JoystickGUID guid = SDL_JoystickGetDeviceGUID(sJoystickIndex);
    char guidString[33] = {};
    SDL_JoystickGetGUIDString(guid, guidString, sizeof(guidString));
    char mapping[512] = {};
    SDL_snprintf(mapping, sizeof(mapping),
                 "%s,2Ship iOS Touch,"
                 "a:b0,b:b1,x:b2,y:b3,back:b4,guide:b5,start:b6,"
                 "leftstick:b7,rightstick:b8,leftshoulder:b9,rightshoulder:b10,"
                 "dpup:b11,dpdown:b12,dpleft:b13,dpright:b14,"
                 "leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:a4,righttrigger:a5,"
                 "platform:iOS,",
                 guidString);
    if (SDL_GameControllerAddMapping(mapping) < 0) {
        SDL_Log("Could not map 2Ship iOS touch controller: %s", SDL_GetError());
        SDL_JoystickDetachVirtual(sJoystickIndex);
        sJoystickIndex = -1;
        return false;
    }
    sJoystick = SDL_JoystickOpen(sJoystickIndex);
    if (sJoystick == nullptr) {
        SDL_Log("Could not open 2Ship iOS touch controller: %s", SDL_GetError());
        SDL_JoystickDetachVirtual(sJoystickIndex);
        sJoystickIndex = -1;
        return false;
    }
    SDL_Log("2Ship iOS touch controller attached at device %d, instance %d",
            sJoystickIndex, SDL_JoystickInstanceID(sJoystick));
    return true;
}

void SetButton(int button, bool pressed) {
    SetDirectButton(N64ButtonForSDLButton(button), pressed);
    if (EnsureController()) {
        SDL_JoystickSetVirtualButton(sJoystick, button, pressed ? SDL_PRESSED : SDL_RELEASED);
    }
}

void SetAxis(int axis, CGFloat value) {
    const int axisValue = static_cast<int>(std::clamp(
        value, static_cast<CGFloat>(SDL_MIN_SINT16), static_cast<CGFloat>(SDL_MAX_SINT16)));
    switch (axis) {
        case kAxisLeftX:
            sTouchLeftX.store(axisValue);
            if (axisValue != 0) {
                sPendingTouchLeftX.store(axisValue);
            }
            break;
        case kAxisLeftY:
            sTouchLeftY.store(axisValue);
            if (axisValue != 0) {
                sPendingTouchLeftY.store(axisValue);
            }
            break;
        case kAxisRightX:
            sTouchRightX.store(axisValue);
            if (axisValue != 0) {
                sPendingTouchRightX.store(axisValue);
            }
            break;
        case kAxisRightY:
            sTouchRightY.store(axisValue);
            if (axisValue != 0) {
                sPendingTouchRightY.store(axisValue);
            }
            break;
        case kAxisLeftTrigger:
            SetDirectButton(0x2000, axisValue > 0);
            break;
        case kAxisRightTrigger:
            SetDirectButton(0x0010, axisValue > 0);
            break;
    }
    if (!EnsureController()) {
        return;
    }
    const bool isRightStickAxis = axis == kAxisRightX || axis == kAxisRightY;
    // During gameplay, the touch right stick is injected directly as an N64
    // right stick. Reporting it through SDL as well would also activate the
    // default C-button axis mappings. Keep SDL reporting available while the
    // settings menu is open so users can bind the touch stick in Input Editor.
    if (!isRightStickAxis || sMenuVisible.load() || axisValue == 0) {
        SDL_JoystickSetVirtualAxis(sJoystick, axis, static_cast<Sint16>(axisValue));
    }
}

} // namespace

@interface TwoShipTouchButton : UIButton
@property(nonatomic) int controllerButton;
@property(nonatomic) int controllerAxis;
@property(nonatomic) Sint16 axisValue;
@property(nonatomic) BOOL inputPressed;
- (instancetype)initWithLabel:(NSString*)label button:(int)button;
- (instancetype)initWithLabel:(NSString*)label axis:(int)axis;
- (void)cancelInput;
@end

@implementation TwoShipTouchButton

- (instancetype)initBase:(NSString*)label {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _controllerButton = -1;
        _controllerAxis = -1;
        self.backgroundColor = ControlFill();
        self.layer.borderColor = ControlStroke().CGColor;
        self.layer.borderWidth = 2.0;
        [self setTitle:label forState:UIControlStateNormal];
        [self setTitleColor:ControlStroke() forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        self.accessibilityLabel = label;
        [self addTarget:self action:@selector(inputDown)
       forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
        [self addTarget:self action:@selector(inputUp)
       forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                        UIControlEventTouchCancel | UIControlEventTouchDragExit];
    }
    return self;
}

- (instancetype)initWithLabel:(NSString*)label button:(int)button {
    self = [self initBase:label];
    if (self) {
        _controllerButton = button;
    }
    return self;
}

- (instancetype)initWithLabel:(NSString*)label axis:(int)axis {
    self = [self initBase:label];
    if (self) {
        _controllerAxis = axis;
        _axisValue = SDL_MAX_SINT16;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    NSString* label = self.currentTitle;
    BOOL isFaceButton = [label isEqualToString:@"A"] || [label isEqualToString:@"B"] ||
                        [label isEqualToString:@"X"] || [label isEqualToString:@"Y"];
    self.layer.cornerRadius = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) *
                              (isFaceButton ? 0.5 : 0.28);
}

- (void)inputDown {
    if (_inputPressed) {
        return;
    }
    _inputPressed = YES;
    self.alpha = 0.55;
    if (_controllerButton >= 0 && _controllerButton != kButtonBack) {
        SetButton(_controllerButton, true);
    } else {
        SetAxis(_controllerAxis, _axisValue);
    }
}

- (void)inputUp {
    if (!_inputPressed) {
        return;
    }
    _inputPressed = NO;
    self.alpha = 1.0;
    if (_controllerButton >= 0 && _controllerButton != kButtonBack) {
        SetButton(_controllerButton, false);
    } else {
        SetAxis(_controllerAxis, 0);
    }
}

- (void)cancelInput {
    [self inputUp];
}

@end

@interface TwoShipTouchStick : UIView
@property(nonatomic, strong) UIView* base;
@property(nonatomic, strong) UIView* knob;
@property(nonatomic) CGPoint origin;
@property(nonatomic) CGFloat diameter;
@property(nonatomic) int axisX;
@property(nonatomic) int axisY;
- (void)cancelInput;
@end

@implementation TwoShipTouchStick

- (instancetype)initWithAxesX:(int)axisX y:(int)axisY label:(NSString*)label {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _axisX = axisX;
        _axisY = axisY;
        _diameter = 132.0;
        self.backgroundColor = UIColor.clearColor;
        self.accessibilityLabel = label;
        _base = [[UIView alloc] initWithFrame:CGRectZero];
        _base.userInteractionEnabled = NO;
        _base.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.20];
        _base.layer.borderColor = ControlStroke().CGColor;
        _base.layer.borderWidth = 2.0;
        _base.hidden = YES;
        [self addSubview:_base];
        _knob = [[UIView alloc] initWithFrame:CGRectZero];
        _knob.userInteractionEnabled = NO;
        _knob.backgroundColor = ControlFill();
        _knob.layer.borderColor = ControlStroke().CGColor;
        _knob.layer.borderWidth = 2.0;
        [_base addSubview:_knob];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _base.bounds = CGRectMake(0, 0, _diameter, _diameter);
    _base.layer.cornerRadius = _diameter * 0.5;
    CGFloat knobSize = _diameter * 0.32;
    _knob.bounds = CGRectMake(0, 0, knobSize, knobSize);
    _knob.layer.cornerRadius = knobSize * 0.5;
    _knob.center = CGPointMake(_diameter * 0.5, _diameter * 0.5);
}

- (void)updateAtPoint:(CGPoint)point {
    CGFloat radius = _diameter * 0.34;
    CGFloat dx = point.x - _origin.x;
    CGFloat dy = point.y - _origin.y;
    CGFloat length = hypot(dx, dy);
    if (length > radius && length > 0) {
        dx *= radius / length;
        dy *= radius / length;
    }
    _knob.center = CGPointMake(_diameter * 0.5 + dx, _diameter * 0.5 + dy);
    SetAxis(_axisX, dx / radius * SDL_MAX_SINT16);
    SetAxis(_axisY, dy / radius * SDL_MAX_SINT16);
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    UITouch* touch = touches.anyObject;
    _origin = [touch locationInView:self];
    _base.center = _origin;
    _base.hidden = NO;
    [self updateAtPoint:_origin];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self updateAtPoint:[touches.anyObject locationInView:self]];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self cancelInput];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self cancelInput];
}

- (void)cancelInput {
    SetAxis(_axisX, 0);
    SetAxis(_axisY, 0);
    _base.hidden = YES;
}

@end

@interface TwoShipTouchOverlay : UIView
@property(nonatomic, strong) UIView* controls;
@property(nonatomic, strong) TwoShipTouchStick* leftStick;
@property(nonatomic, strong) TwoShipTouchStick* rightStick;
@property(nonatomic, strong) NSArray<TwoShipTouchButton*>* buttons;
@property(nonatomic, strong) TwoShipTouchButton* backButton;
@property(nonatomic, strong) UIButton* visibilityButton;
@property(nonatomic) BOOL controlsHidden;
@property(nonatomic) BOOL controlsHiddenBeforeMenu;
@property(nonatomic) BOOL menuVisible;
- (void)setMenuVisible:(BOOL)visible;
- (void)cancelInputs;
@end

@implementation TwoShipTouchOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;
    _controls = [[UIView alloc] initWithFrame:self.bounds];
    _controls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_controls];

    _leftStick = [[TwoShipTouchStick alloc] initWithAxesX:kAxisLeftX y:kAxisLeftY
                                                    label:@"Floating left joystick"];
    _rightStick = [[TwoShipTouchStick alloc] initWithAxesX:kAxisRightX y:kAxisRightY
                                                     label:@"Floating right joystick"];
    [_controls addSubview:_leftStick];
    [_controls addSubview:_rightStick];

    TwoShipTouchButton* a = [[TwoShipTouchButton alloc] initWithLabel:@"A" button:kButtonA];
    TwoShipTouchButton* b = [[TwoShipTouchButton alloc] initWithLabel:@"B" button:kButtonB];
    TwoShipTouchButton* x = [[TwoShipTouchButton alloc] initWithLabel:@"X" button:kButtonX];
    TwoShipTouchButton* y = [[TwoShipTouchButton alloc] initWithLabel:@"Y" button:kButtonY];
    TwoShipTouchButton* zl = [[TwoShipTouchButton alloc] initWithLabel:@"ZL" axis:kAxisLeftTrigger];
    TwoShipTouchButton* l = [[TwoShipTouchButton alloc] initWithLabel:@"L" button:kButtonLeftShoulder];
    TwoShipTouchButton* zr = [[TwoShipTouchButton alloc] initWithLabel:@"ZR" axis:kAxisRightTrigger];
    TwoShipTouchButton* r = [[TwoShipTouchButton alloc] initWithLabel:@"R" button:kButtonRightShoulder];
    _backButton = [[TwoShipTouchButton alloc] initWithLabel:@"Back" button:kButtonBack];
    TwoShipTouchButton* start = [[TwoShipTouchButton alloc] initWithLabel:@"Start" button:kButtonStart];
    TwoShipTouchButton* up = [[TwoShipTouchButton alloc] initWithLabel:@"▲" button:kButtonDpadUp];
    TwoShipTouchButton* down = [[TwoShipTouchButton alloc] initWithLabel:@"▼" button:kButtonDpadDown];
    TwoShipTouchButton* left = [[TwoShipTouchButton alloc] initWithLabel:@"◀" button:kButtonDpadLeft];
    TwoShipTouchButton* right = [[TwoShipTouchButton alloc] initWithLabel:@"▶" button:kButtonDpadRight];
    _buttons = @[ a, b, x, y, zl, l, zr, r, _backButton, start, up, down, left, right ];
    for (TwoShipTouchButton* button in _buttons) {
        [_controls addSubview:button];
    }
    [_backButton addTarget:self action:@selector(toggleMenu)
          forControlEvents:UIControlEventTouchUpInside];

    _visibilityButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [_visibilityButton setTitle:@"◉" forState:UIControlStateNormal];
    [_visibilityButton setTitleColor:ControlStroke() forState:UIControlStateNormal];
    _visibilityButton.titleLabel.font = [UIFont systemFontOfSize:22.0];
    [_visibilityButton addTarget:self action:@selector(toggleControls)
                forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:_visibilityButton];
    return self;
}

- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:point withEvent:event];
    return (hit == self || hit == _controls) ? nil : hit;
}

- (void)toggleMenu {
    sMenuToggleRequested.store(true);
}

- (void)toggleControls {
    _controlsHidden = !_controlsHidden;
    [self applyVisibility];
}

- (void)applyVisibility {
    for (UIView* view in _controls.subviews) {
        view.hidden = _controlsHidden;
    }
    if (_menuVisible) {
        _backButton.hidden = NO;
    }
    // Keep this available in settings. Users can reveal the virtual controls
    // while Input Editor is waiting for a button or axis assignment.
    _visibilityButton.hidden = NO;
}

- (void)setMenuVisible:(BOOL)visible {
    if (_menuVisible == visible) {
        return;
    }
    if (visible) {
        _controlsHiddenBeforeMenu = _controlsHidden;
        _controlsHidden = YES;
    } else {
        _controlsHidden = _controlsHiddenBeforeMenu;
    }
    _menuVisible = visible;
    [self cancelInputs];
    [self applyVisibility];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat scale = std::clamp(height / 390.0, 0.82, 1.2);
    CGFloat edge = 14.0 * scale;
    CGFloat shoulderW = 72.0 * scale;
    CGFloat shoulderH = 34.0 * scale;
    CGFloat gap = 7.0 * scale;

    TwoShipTouchButton* a = _buttons[0];
    TwoShipTouchButton* b = _buttons[1];
    TwoShipTouchButton* x = _buttons[2];
    TwoShipTouchButton* y = _buttons[3];
    TwoShipTouchButton* zl = _buttons[4];
    TwoShipTouchButton* l = _buttons[5];
    TwoShipTouchButton* zr = _buttons[6];
    TwoShipTouchButton* r = _buttons[7];
    TwoShipTouchButton* start = _buttons[9];
    TwoShipTouchButton* up = _buttons[10];
    TwoShipTouchButton* down = _buttons[11];
    TwoShipTouchButton* left = _buttons[12];
    TwoShipTouchButton* right = _buttons[13];

    zl.frame = CGRectMake(safe.left + edge, safe.top + edge, shoulderW, shoulderH);
    l.frame = CGRectMake(safe.left + edge, CGRectGetMaxY(zl.frame) + gap, shoulderW, shoulderH);
    zr.frame = CGRectMake(width - safe.right - edge - shoulderW, safe.top + edge, shoulderW, shoulderH);
    r.frame = CGRectMake(width - safe.right - edge - shoulderW, CGRectGetMaxY(zr.frame) + gap,
                         shoulderW, shoulderH);

    _leftStick.diameter = 142.0 * scale;
    _leftStick.frame = CGRectMake(0, height * 0.34, width * 0.45, height * 0.66);
    _rightStick.diameter = 122.0 * scale;
    _rightStick.frame = CGRectMake(width * 0.52, height * 0.30, width * 0.48, height * 0.70);

    CGFloat face = 45.0 * scale;
    CGFloat offset = 41.0 * scale;
    CGPoint center = CGPointMake(width - safe.right - edge - face - offset,
                                 height - safe.bottom - edge - face - offset);
    for (TwoShipTouchButton* button in @[ a, b, x, y ]) {
        button.bounds = CGRectMake(0, 0, face, face);
    }
    x.center = CGPointMake(center.x, center.y - offset);
    y.center = CGPointMake(center.x - offset, center.y);
    a.center = CGPointMake(center.x + offset, center.y);
    b.center = CGPointMake(center.x, center.y + offset);

    CGFloat dpad = 34.0 * scale;
    CGPoint dpadCenter = CGPointMake(safe.left + edge + 102.0 * scale,
                                     height - safe.bottom - edge - 195.0 * scale);
    up.frame = CGRectMake(dpadCenter.x - dpad * 0.5, dpadCenter.y - dpad * 1.5, dpad, dpad);
    down.frame = CGRectMake(dpadCenter.x - dpad * 0.5, dpadCenter.y + dpad * 0.5, dpad, dpad);
    left.frame = CGRectMake(dpadCenter.x - dpad * 1.5, dpadCenter.y - dpad * 0.5, dpad, dpad);
    right.frame = CGRectMake(dpadCenter.x + dpad * 0.5, dpadCenter.y - dpad * 0.5, dpad, dpad);

    CGFloat systemW = 50.0 * scale;
    CGFloat systemH = 28.0 * scale;
    CGFloat centerX = width * 0.5;
    _backButton.frame = CGRectMake(centerX - 85.0 * scale - systemW * 0.5,
                                   height - safe.bottom - systemH - 8.0 * scale, systemW, systemH);
    start.frame = CGRectMake(centerX + 85.0 * scale - systemW * 0.5,
                             height - safe.bottom - systemH - 8.0 * scale, systemW, systemH);
    _visibilityButton.frame = CGRectMake(width - safe.right - 42.0 * scale,
                                         height - safe.bottom - 42.0 * scale, 32.0 * scale, 32.0 * scale);
    [_controls sendSubviewToBack:_rightStick];
    [_controls sendSubviewToBack:_leftStick];
    [self applyVisibility];
}

- (void)cancelInputs {
    [_leftStick cancelInput];
    [_rightStick cancelInput];
    for (TwoShipTouchButton* button in _buttons) {
        [button cancelInput];
    }
}

@end

static TwoShipTouchOverlay* sOverlay;
static BOOL sControlsDesired;

static UIWindow* ActiveWindow() {
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow* window in ((UIWindowScene*)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

static void ApplyState() {
    UIWindow* window = ActiveWindow();
    if (window == nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                       dispatch_get_main_queue(), ^{ ApplyState(); });
        return;
    }
    if (!sControlsDesired) {
        [sOverlay cancelInputs];
        [sOverlay removeFromSuperview];
        sOverlay = nil;
        return;
    }
    if (sOverlay == nil) {
        sOverlay = [[TwoShipTouchOverlay alloc] initWithFrame:window.bounds];
        sOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    if (sOverlay.superview != window) {
        [sOverlay removeFromSuperview];
        sOverlay.frame = window.bounds;
        [window addSubview:sOverlay];
    }
    [sOverlay setMenuVisible:sMenuVisible.load()];
    [window bringSubviewToFront:sOverlay];
}

void TwoShipIOS_SetTouchControlsEnabled(int enabled) {
    dispatch_async(dispatch_get_main_queue(), ^{
        sControlsDesired = enabled != 0;
        ApplyState();
    });
}

void TwoShipIOS_SetTouchControlsMenuVisible(int visible) {
    const bool newValue = visible != 0;
    if (sMenuVisible.exchange(newValue) == newValue) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ ApplyState(); });
}

int TwoShipIOS_ConsumeMenuToggleRequest(void) {
    return sMenuToggleRequested.exchange(false) ? 1 : 0;
}

void TwoShipIOS_PrepareTouchController(void) {
    EnsureController();
}

void TwoShipIOS_GetTouchPadState(uint16_t* buttons, int8_t* leftX, int8_t* leftY,
                                 int8_t* rightX, int8_t* rightY) {
    constexpr int kN64StickRange = 85;
    auto scaleAxis = [kN64StickRange](int value) {
        return static_cast<int8_t>(std::clamp(
            static_cast<int>(std::lround(value * kN64StickRange /
                                         static_cast<double>(SDL_MAX_SINT16))),
            -kN64StickRange, kN64StickRange));
    };
    auto consumeAxis = [](std::atomic_int& current, std::atomic_int& pending) {
        const int currentValue = current.load();
        if (currentValue != 0) {
            pending.store(0);
            return currentValue;
        }
        return pending.exchange(0);
    };
    *buttons = sTouchButtons.load() | sPendingTouchButtons.exchange(0);
    *leftX = scaleAxis(consumeAxis(sTouchLeftX, sPendingTouchLeftX));
    *leftY = -scaleAxis(consumeAxis(sTouchLeftY, sPendingTouchLeftY));
    *rightX = scaleAxis(consumeAxis(sTouchRightX, sPendingTouchRightX));
    *rightY = -scaleAxis(consumeAxis(sTouchRightY, sPendingTouchRightY));
}

void TwoShipIOS_GetCurrentRightStick(int8_t* rightX, int8_t* rightY) {
    constexpr int kN64StickRange = 85;
    auto scaleAxis = [kN64StickRange](int value) {
        return static_cast<int8_t>(std::clamp(
            static_cast<int>(std::lround(value * kN64StickRange /
                                         static_cast<double>(SDL_MAX_SINT16))),
            -kN64StickRange, kN64StickRange));
    };
    *rightX = scaleAxis(sTouchRightX.load());
    *rightY = -scaleAxis(sTouchRightY.load());
}

int TwoShipApple_GetNativeControllerGyro(float* gyroX, float* gyroY, float* gyroZ) {
    if (gyroX == nullptr || gyroY == nullptr || gyroZ == nullptr) {
        return 0;
    }

    *gyroX = 0.0f;
    *gyroY = 0.0f;
    *gyroZ = 0.0f;
    for (GCController* controller in GCController.controllers) {
        GCMotion* motion = controller.motion;
        if (controller.extendedGamepad == nil || motion == nil || !motion.hasRotationRate) {
            continue;
        }
        if (motion.sensorsRequireManualActivation) {
            motion.sensorsActive = YES;
        }
        const GCRotationRate rate = motion.rotationRate;
        *gyroX = (float)rate.x;
        *gyroY = (float)rate.y;
        *gyroZ = (float)rate.z;
        return 1; // Connected controller motion has priority.
    }

    @synchronized([CMMotionManager class]) {
        if (sDeviceMotionManager == nil) {
            sDeviceMotionManager = [[CMMotionManager alloc] init];
            sDeviceMotionManager.gyroUpdateInterval = 1.0 / 120.0;
        }
        if (!sDeviceMotionManager.gyroAvailable) {
            return 0;
        }
        if (!sDeviceMotionManager.gyroActive) {
            [sDeviceMotionManager startGyroUpdates];
        }
    }

    CMGyroData* gyroData = sDeviceMotionManager.gyroData;
    if (gyroData == nil) {
        // Core Motion needs at least one sample after startup.
        return 0;
    }

    const float rawX = (float)gyroData.rotationRate.x;
    const float rawY = (float)gyroData.rotationRate.y;
    *gyroZ = (float)gyroData.rotationRate.z;
    switch (SDL_GetDisplayOrientation(0)) {
        case SDL_ORIENTATION_PORTRAIT:
            *gyroX = rawX;
            *gyroY = rawY;
            break;
        case SDL_ORIENTATION_PORTRAIT_FLIPPED:
            *gyroX = -rawX;
            *gyroY = -rawY;
            break;
        case SDL_ORIENTATION_LANDSCAPE:
            *gyroX = -rawY;
            *gyroY = rawX;
            break;
        case SDL_ORIENTATION_LANDSCAPE_FLIPPED:
            *gyroX = rawY;
            *gyroY = -rawX;
            break;
        case SDL_ORIENTATION_UNKNOWN:
            *gyroX = rawX;
            *gyroY = rawY;
            break;
    }
    return 2; // Built-in iPhone or iPad gyro.
}
