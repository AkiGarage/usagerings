export const title = '縦タブの画面への適合';
export const state = v => v.rendered < v.chosen ? '表示だけ縮小' : '指定した大きさ';
export const step = () => '画面または向きを変更';
