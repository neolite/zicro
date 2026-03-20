# Mach Engine Integration Blocker

## Issue
Attempted to integrate Mach Engine (commit 173ed0cf) but encountered critical version incompatibility:

```
error: unsupported Zig version (0.15.2).
Required Zig version 2024.11.0-mach
```

## Root Cause
Mach Engine requires a **custom Zig build** (2024.11.0-mach), not standard Zig releases. This is a fork/custom version maintained by the Mach team.

## Impact
- Cannot use Mach Engine with standard Zig 0.15.2
- Would require switching entire project to custom Zig compiler
- Adds significant complexity and maintenance burden
- Breaks compatibility with standard Zig ecosystem

## Options

### Option 1: Use Mach Custom Zig
**Pros**: Can use Mach Engine as planned
**Cons**:
- Custom compiler (not standard Zig)
- Potential compatibility issues with other dependencies (vaxis)
- Harder for contributors (need custom Zig)
- Uncertain update path

### Option 2: Wait for Mach Zig Compatibility
**Pros**: Eventually might support standard Zig
**Cons**:
- Unknown timeline (could be months/years)
- No guarantee it will happen

### Option 3: Alternative GUI Framework
**Pros**: Use standard Zig ecosystem
**Cons**:
- Back to square one on GUI framework selection
- All alternatives have issues (Capy no macOS, GTK Linux-only)

### Option 4: Terminal First (Recommended)
**Pros**:
- Works with current Zig 0.15.2
- zicro-core already extracted
- Can polish terminal version to production-ready
- Monitor GUI ecosystem maturity
**Cons**:
- Delays GUI version
- Terminal UI limitations

## Recommendation

**Pivot to "Terminal First" strategy** (Option 4):

1. **Immediate (Weeks 1-4)**: Polish terminal version using zicro-core
2. **Monitor (Months 2-6)**: Track Mach/Capy/ecosystem developments
3. **Decide (Month 6)**: Re-evaluate GUI options when ecosystem matures

This aligns with the original plan's "Variant E" which we discussed but didn't choose. The Mach blocker validates that the GUI ecosystem isn't ready yet.

## Next Steps

1. Document this finding in main plan
2. Focus on terminal version improvements
3. Set up monitoring for:
   - Mach Zig version compatibility
   - Capy macOS support
   - Other emerging Zig GUI frameworks
