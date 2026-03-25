# Standing Acceptance Criteria

These criteria apply to **every UI task**. Claude generates task-specific AC as children under these categories.

## Visual & Layout
- All UI elements render without clipping or overflow
- Layout holds at target viewport dimensions (393x852, 430x932)
- No visual regressions in adjacent screens

## Functional
- All interactive elements respond to tap/press
- Navigation flows complete without dead ends
- Loading, empty, and error states all render correctly

## Data
- Data persists correctly to Supabase
- RLS policies allow/deny as expected for the current user role
- Optimistic updates revert cleanly on failure

## Code Quality
- No console errors or warnings
- No TypeScript compiler errors
- Accessibility labels present on all interactive elements

## Integration
- Component renders within the existing navigation structure
- No regressions in previously passing acceptance criteria
