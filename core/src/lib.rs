//! Platform-independent placement policy. Coordinates use macOS AX top-left points.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[no_mangle]
pub extern "C" fn harbor_place(window: Rect, screen: Rect) -> Rect {
    let width = window.width.max(1.0).min(screen.width.max(1.0));
    let height = window.height.max(1.0).min(screen.height.max(1.0));
    Rect {
        x: window
            .x
            .clamp(screen.x, screen.x + (screen.width - width).max(0.0)),
        y: window
            .y
            .clamp(screen.y, screen.y + (screen.height - height).max(0.0)),
        width,
        height,
    }
}

/// Whether a settled topology deserves exactly one automatic run.
#[no_mangle]
pub extern "C" fn harbor_should_run(
    enabled: bool,
    trusted: bool,
    external_count: u32,
    changed: bool,
) -> bool {
    enabled && trusted && external_count > 0 && changed
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn negative_origin_and_oversized_window() {
        assert_eq!(
            harbor_place(
                Rect {
                    x: 4000.,
                    y: 0.,
                    width: 2000.,
                    height: 1400.
                },
                Rect {
                    x: -1440.,
                    y: 25.,
                    width: 1440.,
                    height: 875.
                }
            ),
            Rect {
                x: -1440.,
                y: 25.,
                width: 1440.,
                height: 875.
            }
        );
    }
    #[test]
    fn preserve_existing_main_position() {
        let r = Rect {
            x: 120.,
            y: 150.,
            width: 700.,
            height: 500.,
        };
        assert_eq!(
            harbor_place(
                r,
                Rect {
                    x: 0.,
                    y: 25.,
                    width: 1440.,
                    height: 875.
                }
            ),
            r
        );
    }
    #[test]
    fn automatic_gate() {
        assert!(harbor_should_run(true, true, 1, true));
        assert!(!harbor_should_run(false, true, 1, true));
        assert!(!harbor_should_run(true, true, 0, true));
        assert!(!harbor_should_run(true, true, 1, false));
    }
    #[test]
    fn wait_for_permission_then_run_same_topology() {
        // Denied access must not turn an unprocessed topology into a completed run.
        let mut pending = true;
        for trusted in [false, false, true] {
            if harbor_should_run(true, trusted, 1, pending) {
                assert!(trusted);
                pending = false;
            } else {
                assert!(!trusted);
                assert!(pending);
            }
        }
        assert!(!pending);
        assert!(!harbor_should_run(true, true, 1, pending));
    }
}
