#import "NativeChrome.h"

static NSColor *RGB(unsigned int rgb) {
  return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0
                              blue:(rgb & 0xff) / 255.0 alpha:1];
}

#pragma mark - Icons

NSImage *NativeFloppyIcon(NSColor *color, CGFloat size) {
  return [NSImage imageWithSize:NSMakeSize(size, size) flipped:YES drawingHandler:^BOOL(NSRect rect) {
    CGFloat unit = rect.size.width / 16.0;
    NSRect body = NSInsetRect(rect, unit * 1.5, unit * 1.5);
    NSBezierPath *outline = [NSBezierPath bezierPath];
    CGFloat cut = unit * 2.5;
    [outline moveToPoint:NSMakePoint(NSMinX(body), NSMinY(body))];
    [outline lineToPoint:NSMakePoint(NSMaxX(body) - cut, NSMinY(body))];
    [outline lineToPoint:NSMakePoint(NSMaxX(body), NSMinY(body) + cut)];
    [outline lineToPoint:NSMakePoint(NSMaxX(body), NSMaxY(body))];
    [outline lineToPoint:NSMakePoint(NSMinX(body), NSMaxY(body))];
    [outline closePath];
    [color setFill];
    [outline fill];
    [[color blendedColorWithFraction:0.45 ofColor:NSColor.blackColor] setStroke];
    outline.lineWidth = unit * 0.8;
    [outline stroke];
    // Metal shutter at the top and white label at the bottom.
    [[NSColor colorWithWhite:0.92 alpha:1] setFill];
    NSRectFill(NSMakeRect(NSMinX(body) + unit * 3, NSMinY(body) + unit * 0.6, unit * 6.5, unit * 4.2));
    [[color blendedColorWithFraction:0.35 ofColor:NSColor.blackColor] setFill];
    NSRectFill(NSMakeRect(NSMinX(body) + unit * 7.2, NSMinY(body) + unit * 1.3, unit * 1.5, unit * 2.8));
    [NSColor.whiteColor setFill];
    NSRectFill(NSMakeRect(NSMinX(body) + unit * 2, NSMinY(body) + unit * 7.2, NSWidth(body) - unit * 4, unit * 5.2));
    return YES;
  }];
}

NSImage *NativeSaveAllIcon(CGFloat size) {
  NSImage *front = NativeFloppyIcon(RGB(0x2F6FD0), size * 0.78);
  NSImage *back = NativeFloppyIcon(RGB(0x6E9BE0), size * 0.78);
  return [NSImage imageWithSize:NSMakeSize(size, size) flipped:NO drawingHandler:^BOOL(NSRect rect) {
    (void)rect;
    [back drawInRect:NSMakeRect(size * 0.22, size * 0.22, size * 0.78, size * 0.78)];
    [front drawInRect:NSMakeRect(0, 0, size * 0.78, size * 0.78)];
    return YES;
  }];
}

NSImage *NativeSymbolIcon(NSString *name, NSArray<NSColor *> *palette, CGFloat pointSize) {
  if (@available(macOS 12.0, *)) {
    NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:name];
    if (!image) return nil;
    NSImageSymbolConfiguration *configuration = [NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:NSFontWeightRegular];
    configuration = [configuration configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:palette]];
    return [image imageWithSymbolConfiguration:configuration];
  }
  return nil;
}

NSColor *NativeTabColor(NSInteger index) {
  switch (index) {
    case 1: return RGB(0xF7D85C);
    case 2: return RGB(0x7CCF7C);
    case 3: return RGB(0x7FB4F0);
    case 4: return RGB(0xF5A55A);
    case 5: return RGB(0xF09AD6);
    default: return nil;
  }
}

#pragma mark - Tab bar

static const CGFloat kTabHeight = 25;
static const CGFloat kTabMaxWidth = 230;
static const CGFloat kTabMinWidth = 70;

@interface NativeTabBar ()
@property(nonatomic, strong) NSArray<NSValue *> *tabRects;
@property(nonatomic, assign) NSInteger hoverIndex;
@property(nonatomic, assign) NSInteger pressedCloseIndex;
@property(nonatomic, strong, nullable) NSTrackingArea *trackingArea;
@end

@implementation NativeTabBar

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _tabRects = @[];
    _hoverIndex = -1;
    _pressedCloseIndex = -1;
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kTabHeight + 3);
}

- (NSDictionary *)titleAttributesActive:(BOOL)active {
  NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
  paragraph.lineBreakMode = NSLineBreakByTruncatingMiddle;
  NSColor *color = active ? (self.dark ? RGB(0xF0F0F0) : NSColor.blackColor) : (self.dark ? RGB(0x9A9A9A) : RGB(0x6A6A6A));
  return @{NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: color,
           NSParagraphStyleAttributeName: paragraph};
}

- (void)reload {
  NSArray<NSTabViewItem *> *items = self.tabView.tabViewItems ?: @[];
  NSMutableArray<NSNumber *> *widths = [NSMutableArray arrayWithCapacity:items.count];
  CGFloat total = 0;
  for (NSTabViewItem *item in items) {
    CGFloat text = ceil([item.label sizeWithAttributes:[self titleAttributesActive:YES]].width);
    BOOL pinned = self.pinnedProvider && self.pinnedProvider(item);
    CGFloat width = MIN(kTabMaxWidth, MAX(kTabMinWidth, 6 + 16 + 5 + text + 8 + 13 + 6 + (pinned ? 16 : 0)));
    [widths addObject:@(width)];
    total += width;
  }
  CGFloat available = NSWidth(self.bounds) - 4;
  CGFloat scale = total > available && total > 0 ? MAX(available / total, 0.1) : 1;
  NSMutableArray *rects = [NSMutableArray arrayWithCapacity:items.count];
  CGFloat x = 2;
  for (NSNumber *width in widths) {
    CGFloat scaled = floor(MAX(48, width.doubleValue * scale));
    [rects addObject:[NSValue valueWithRect:NSMakeRect(x, 3, scaled, kTabHeight)]];
    x += scaled;
  }
  self.tabRects = rects;
  [self removeAllToolTips];
  [items enumerateObjectsUsingBlock:^(NSTabViewItem *item, NSUInteger index, BOOL *stop) {
    (void)stop;
    NSString *tip = self.toolTipProvider ? self.toolTipProvider(item) : nil;
    if (tip) [self addToolTipRect:self.tabRects[index].rectValue owner:tip userData:NULL];
  }];
  self.needsDisplay = YES;
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self reload];
}

- (NSRect)closeRectForTab:(NSRect)tab {
  return NSMakeRect(NSMaxX(tab) - 19, NSMidY(tab) - 6, 13, 13);
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  NSColor *background = self.dark ? RGB(0x2B2B2B) : RGB(0xF0F0F0);
  NSColor *inactive = self.dark ? RGB(0x333333) : RGB(0xE3E3E3);
  NSColor *active = self.dark ? RGB(0x1E1E1E) : NSColor.whiteColor;
  NSColor *border = self.dark ? RGB(0x4A4A4A) : RGB(0xB9B9B9);
  [background setFill];
  NSRectFill(self.bounds);
  [border setFill];
  NSRectFill(NSMakeRect(0, NSMaxY(self.bounds) - 1, NSWidth(self.bounds), 1));

  NSArray<NSTabViewItem *> *items = self.tabView.tabViewItems ?: @[];
  NSTabViewItem *selected = self.tabView.selectedTabViewItem;
  for (NSUInteger index = 0; index < items.count && index < self.tabRects.count; index += 1) {
    NSTabViewItem *item = items[index];
    NSRect tab = self.tabRects[index].rectValue;
    BOOL isActive = item == selected;
    BOOL hover = (NSInteger)index == self.hoverIndex;
    NSRect fill = isActive ? NSMakeRect(NSMinX(tab), NSMinY(tab) - 2, NSWidth(tab), NSHeight(tab) + 2) : NSInsetRect(tab, 0, 1);
    NSColor *fillColor = isActive ? active : (hover ? [inactive blendedColorWithFraction:0.4 ofColor:active] : inactive);
    NSColor *tint = NativeTabColor(self.colorProvider ? self.colorProvider(item) : 0);
    if (tint) fillColor = [fillColor blendedColorWithFraction:isActive ? 0.35 : 0.55 ofColor:tint];
    [fillColor setFill];
    NSRectFill(fill);
    [border setStroke];
    NSBezierPath *edge = [NSBezierPath bezierPath];
    edge.lineWidth = 1;
    [edge moveToPoint:NSMakePoint(NSMinX(fill) + 0.5, NSMaxY(fill))];
    [edge lineToPoint:NSMakePoint(NSMinX(fill) + 0.5, NSMinY(fill) + 0.5)];
    [edge lineToPoint:NSMakePoint(NSMaxX(fill) - 0.5, NSMinY(fill) + 0.5)];
    [edge lineToPoint:NSMakePoint(NSMaxX(fill) - 0.5, NSMaxY(fill))];
    [edge stroke];
    if (isActive) {
      // Notepad++ marks the active tab with an orange bar along its top edge.
      [RGB(0xFAA43A) setFill];
      NSRectFill(NSMakeRect(NSMinX(fill) + 1, NSMinY(fill) + 1, NSWidth(fill) - 2, 3));
      [active setFill];
      NSRectFill(NSMakeRect(NSMinX(fill) + 1, NSMaxY(self.bounds) - 1, NSWidth(fill) - 2, 1));
    }

    NativeTabState state = self.stateProvider ? self.stateProvider(item) : NativeTabStateSaved;
    NSColor *iconColor = state == NativeTabStateModified ? RGB(0xD9363E)
                       : state == NativeTabStateReadOnly ? RGB(0x8C8C8C)
                       : state == NativeTabStateMonitoring ? RGB(0x2E9E48) : RGB(0x2F6FD0);
    NSRect iconRect = NSMakeRect(NSMinX(tab) + 6, NSMidY(tab) - 8 + (isActive ? 0 : 1), 16, 16);
    [NativeFloppyIcon(iconColor, 16) drawInRect:iconRect];

    BOOL showClose = isActive || hover;
    BOOL pinned = self.pinnedProvider && self.pinnedProvider(item);
    CGFloat textRight = showClose ? NSMaxX(tab) - 22 : NSMaxX(tab) - 6;
    if (pinned) {
      textRight -= 16;
      NSImage *pin = NativeSymbolIcon(@"pin.fill", @[RGB(0x5A5A5A)], 10);
      [pin drawInRect:NSMakeRect(textRight + 2, NSMidY(tab) - 6, 12, 12)];
    }
    NSRect textRect = NSMakeRect(NSMaxX(iconRect) + 5, NSMidY(tab) - 8 + (isActive ? 0 : 1), textRight - NSMaxX(iconRect) - 5, 16);
    [item.label drawWithRect:textRect options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                  attributes:[self titleAttributesActive:isActive]];

    if (showClose) {
      NSRect close = [self closeRectForTab:tab];
      BOOL pressed = (NSInteger)index == self.pressedCloseIndex;
      NSColor *red = isActive ? RGB(0xE0433E) : RGB(0xB0B0B0);
      [(pressed ? red : [red colorWithAlphaComponent:0.12]) setFill];
      NSRectFill(close);
      [red setStroke];
      NSBezierPath *box = [NSBezierPath bezierPathWithRect:NSInsetRect(close, 0.5, 0.5)];
      box.lineWidth = 1;
      [box stroke];
      NSBezierPath *cross = [NSBezierPath bezierPath];
      cross.lineWidth = 1.6;
      [cross moveToPoint:NSMakePoint(NSMinX(close) + 3.5, NSMinY(close) + 3.5)];
      [cross lineToPoint:NSMakePoint(NSMaxX(close) - 3.5, NSMaxY(close) - 3.5)];
      [cross moveToPoint:NSMakePoint(NSMaxX(close) - 3.5, NSMinY(close) + 3.5)];
      [cross lineToPoint:NSMakePoint(NSMinX(close) + 3.5, NSMaxY(close) - 3.5)];
      [(pressed ? NSColor.whiteColor : red) setStroke];
      [cross stroke];
    }
  }
}

- (NSInteger)indexAtPoint:(NSPoint)point {
  for (NSUInteger index = 0; index < self.tabRects.count; index += 1) {
    if (NSPointInRect(point, self.tabRects[index].rectValue)) return (NSInteger)index;
  }
  return -1;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
  self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
      options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
  [self addTrackingArea:self.trackingArea];
}

- (void)mouseMoved:(NSEvent *)event {
  NSInteger index = [self indexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  if (index != self.hoverIndex) {
    self.hoverIndex = index;
    self.needsDisplay = YES;
  }
}

- (void)mouseExited:(NSEvent *)event {
  (void)event;
  self.hoverIndex = -1;
  self.needsDisplay = YES;
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger index = [self indexAtPoint:point];
  if (index < 0) {
    if (event.clickCount == 2 && self.newTabHandler) self.newTabHandler();
    return;
  }
  NSTabViewItem *item = self.tabView.tabViewItems[index];
  NSRect tab = self.tabRects[index].rectValue;
  if (event.clickCount == 2 && self.doubleClickCloses && self.closeHandler) {
    self.closeHandler(item);
    return;
  }
  BOOL closeVisible = item == self.tabView.selectedTabViewItem || index == self.hoverIndex;
  if (closeVisible && NSPointInRect(point, NSInsetRect([self closeRectForTab:tab], -2, -2))) {
    self.pressedCloseIndex = index;
    self.needsDisplay = YES;
    NSEvent *up = [self.window nextEventMatchingMask:NSEventMaskLeftMouseUp];
    self.pressedCloseIndex = -1;
    self.needsDisplay = YES;
    NSPoint upPoint = [self convertPoint:up.locationInWindow fromView:nil];
    if (NSPointInRect(upPoint, NSInsetRect([self closeRectForTab:tab], -2, -2)) && self.closeHandler) self.closeHandler(item);
    return;
  }

  [self.tabView selectTabViewItem:item];
  [self reload];
  // Drag left or right to reorder (unless the tab bar is locked).
  NSTabViewItem *lastSwapped = nil;
  while (!self.locked) {
    NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp];
    if (next.type == NSEventTypeLeftMouseUp) break;
    NSPoint location = [self convertPoint:next.locationInWindow fromView:nil];
    location.y = NSMidY(tab);
    NSInteger overIndex = [self indexAtPoint:location];
    NSTabViewItem *over = overIndex >= 0 ? self.tabView.tabViewItems[overIndex] : nil;
    if (!over || over == item) {
      lastSwapped = nil;
      continue;
    }
    if (over == lastSwapped) continue;
    NSInteger from = [self.tabView indexOfTabViewItem:item];
    [self.tabView removeTabViewItem:item];
    [self.tabView insertTabViewItem:item atIndex:overIndex];
    [self.tabView selectTabViewItem:item];
    lastSwapped = over;
    if (self.reorderHandler) self.reorderHandler(from, overIndex);
    [self reload];
  }
}

- (void)otherMouseUp:(NSEvent *)event {
  NSInteger index = [self indexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  if (index >= 0 && self.closeHandler) self.closeHandler(self.tabView.tabViewItems[index]);
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
  NSInteger index = [self indexAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  if (index < 0 || !self.menuProvider) return nil;
  NSTabViewItem *item = self.tabView.tabViewItems[index];
  [self.tabView selectTabViewItem:item];
  [self reload];
  return self.menuProvider(item);
}

- (void)scrollWheel:(NSEvent *)event {
  // Wheel over the tab strip switches tabs, as in Notepad++.
  CGFloat delta = fabs(event.scrollingDeltaY) > fabs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX;
  if (fabs(delta) < 1 || event.momentumPhase != NSEventPhaseNone) return;
  NSInteger count = self.tabView.numberOfTabViewItems;
  if (count < 2) return;
  NSInteger index = [self.tabView indexOfTabViewItem:self.tabView.selectedTabViewItem];
  NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if ((flags & NSEventModifierFlagShift) && !(flags & NSEventModifierFlagControl) && !self.locked) {
    // Shift+wheel moves the current tab (wrapping), as in Notepad++.
    NSInteger target = (index + (delta > 0 ? -1 : 1) + count) % count;
    NSTabViewItem *item = self.tabView.selectedTabViewItem;
    [self.tabView removeTabViewItem:item];
    [self.tabView insertTabViewItem:item atIndex:target];
    [self.tabView selectTabViewItem:item];
    if (self.reorderHandler) self.reorderHandler(index, target);
  } else if ((flags & NSEventModifierFlagShift) && (flags & NSEventModifierFlagControl)) {
    [self.tabView selectTabViewItemAtIndex:delta > 0 ? 0 : count - 1];
  } else if (flags & NSEventModifierFlagControl) {
    [self.tabView selectTabViewItemAtIndex:(index + (delta > 0 ? -1 : 1) + count) % count];
  } else {
    index = delta > 0 ? MAX(0, index - 1) : MIN(count - 1, index + 1);
    [self.tabView selectTabViewItemAtIndex:index];
  }
  [self reload];
}

@end

#pragma mark - Status bar

@interface NativeStatusBar ()
@property(nonatomic, strong) NSMutableArray<NSTextField *> *labels;
@end

@implementation NativeStatusBar

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) _labels = [NSMutableArray array];
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, 22);
}

- (void)setFields:(NSArray<NSString *> *)fields {
  while (self.labels.count < fields.count) {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.font = [NSFont systemFontOfSize:11];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:label];
    [self.labels addObject:label];
  }
  [self.labels enumerateObjectsUsingBlock:^(NSTextField *label, NSUInteger index, BOOL *stop) {
    (void)stop;
    label.hidden = index >= fields.count;
    if (index < fields.count && ![label.stringValue isEqualToString:fields[index]]) label.stringValue = fields[index];
    label.textColor = self.dark ? RGB(0xD0D0D0) : NSColor.blackColor;
  }];
  self.needsLayout = YES;
  self.needsDisplay = YES;
}

- (void)layout {
  [super layout];
  NSArray<NSNumber *> *minimums = @[@0, @190, @220, @110, @90, @36];
  NSUInteger count = 0;
  for (NSTextField *label in self.labels) if (!label.hidden) count += 1;
  CGFloat x = NSWidth(self.bounds);
  for (NSInteger index = (NSInteger)count - 1; index >= 1; index -= 1) {
    NSTextField *label = self.labels[index];
    CGFloat minimum = (NSUInteger)index < minimums.count ? minimums[index].doubleValue : 60;
    CGFloat width = MAX(minimum, ceil(label.intrinsicContentSize.width) + 16);
    x -= width;
    label.frame = NSMakeRect(x + 8, 3, width - 12, 16);
  }
  if (count) self.labels[0].frame = NSMakeRect(6, 3, MAX(0, x - 12), 16);
}

- (void)drawRect:(NSRect)dirtyRect {
  (void)dirtyRect;
  [(self.dark ? RGB(0x2B2B2B) : RGB(0xF0F0F0)) setFill];
  NSRectFill(self.bounds);
  NSColor *line = self.dark ? RGB(0x4A4A4A) : RGB(0xB9B9B9);
  [line setFill];
  NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 1));
  for (NSUInteger index = 1; index < self.labels.count; index += 1) {
    if (self.labels[index].hidden) continue;
    CGFloat x = NSMinX(self.labels[index].frame) - 7;
    NSRectFill(NSMakeRect(x, 3, 1, NSHeight(self.bounds) - 6));
  }
}

@end
