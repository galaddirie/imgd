export const DEFAULT_VIEWPORT = { zoom: 1.2, x: 100, y: 50 }
export const DOUBLE_CLICK_DELAY_MS = 250
export const CURSOR_THROTTLE_MS = 50

export const DEFAULT_NODE_DIMENSIONS = { width: 150, height: 50 }
export const EDGE_LABEL_DIMENSIONS = { width: 40, height: 12 }
export const EDGE_LABEL_PADDING = 6
export const EDGE_LABEL_POSITION = 0.6
export const EDGE_LABEL_HALF_WIDTH = EDGE_LABEL_DIMENSIONS.width / 2 + EDGE_LABEL_PADDING
export const EDGE_LABEL_HALF_HEIGHT = EDGE_LABEL_DIMENSIONS.height / 2 + EDGE_LABEL_PADDING
export const EDGE_LABEL_GAP = Math.ceil((EDGE_LABEL_HALF_WIDTH / (1 - EDGE_LABEL_POSITION)) * 2)
