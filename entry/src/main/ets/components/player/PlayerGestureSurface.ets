/** 播放画面的手势命中面：由播放器在控件显示/隐藏两种布局中复用。 */
@Component
export struct PlayerGestureSurface {
  onSingleTap: (event: GestureEvent) => void = () => {};
  onDoubleTap: () => void = () => {};
  onPanStart: (event: GestureEvent) => void = () => {};
  onPanUpdate: (event: GestureEvent) => void = () => {};
  onPanEnd: () => void = () => {};
  onLongPressStart: () => void = () => {};
  onLongPressEnd: () => void = () => {};
  onTouchDown: (x: number, y: number) => void = () => {};

  build() {
    Stack()
      .width('100%')
      .height('100%')
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 }).onAction(() => this.onDoubleTap()),
          TapGesture({ count: 1 }).onAction((event: GestureEvent) => this.onSingleTap(event)),
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 12 })
            .onActionStart((event: GestureEvent) => this.onPanStart(event))
            .onActionUpdate((event: GestureEvent) => this.onPanUpdate(event))
            .onActionEnd(() => this.onPanEnd())
            .onActionCancel(() => this.onPanEnd())
        )
      )
      .priorityGesture(
        LongPressGesture({ fingers: 1, repeat: false, duration: 350 })
          .onAction(() => this.onLongPressStart())
          .onActionEnd(() => this.onLongPressEnd())
          .onActionCancel(() => this.onLongPressEnd())
      )
      .onTouch((event: TouchEvent) => {
        if (event.type !== TouchType.Down || event.touches.length === 0) return;
        this.onTouchDown(event.touches[0].x, event.touches[0].y);
      })
  }
}
