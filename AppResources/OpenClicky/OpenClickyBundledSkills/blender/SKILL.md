---
name: blender-toolkit
description: |
  Blender automation with geometry creation, materials, modifiers, and Mixamo animation retargeting.

  Core Features: WebSocket-based real-time control, automatic bone mapping with UI review, two-phase confirmation workflow, quality assessment, multi-project support, comprehensive CLI commands.

  Use Cases: Create 3D primitives (cube, sphere, cylinder, etc.), manipulate objects (transform, duplicate, delete), manage materials and modifiers, retarget Mixamo animations to custom rigs with fuzzy bone matching.

allowed-tools: Bash, Read, Write, Glob
---

## ⚠️ Installation Check (READ THIS FIRST)

**IMPORTANT**: Before using this skill, check Blender addon installation status.

**Config location**: Check the shared config file for your installation status:
```
~/.claude/plugins/marketplaces/dev-gom-plugins/blender-config.json
```

**Always run scripts with `--help` first** to see usage. DO NOT read the source until you try running the script first and find that a customized solution is abslutely necessary. These scripts can be very large and thus pollute your context window. They exist to be called directly as black-box scripts rather than ingested into your context window.

**Required actions based on config**:

### 1. If Blender Not Detected (`blenderExecutable: null`)

Blender was not found during initialization. Please:

1. **Install Blender 4.0+** from https://www.blender.org
2. **Restart Claude Code session** to trigger auto-detection
3. Check logs: `.blender-toolkit/init-log.txt`

### 2. If Multiple Versions Detected (`detectedBlenderVersions` array)

The system detected multiple Blender installations. If you want to use a different version:

1. **Open config file** (path shown above)
2. **Edit `blenderExecutable`** field to your preferred version path
3. **Restart Claude Code session**

Example:
```json
{
  "detectedBlenderVersions": [
    {"version": "4.2.0", "path": "C:\\Program Files\\Blender Foundation\\Blender 4.2\\blender.exe"},
    {"version": "4.1.0", "path": "C:\\Program Files\\Blender Foundation\\Blender 4.1\\blender.exe"}
  ],
  "blenderExecutable": "C:\\Program Files\\Blender Foundation\\Blender 4.2\\blender.exe"
}
```

### 3. If Addon Not Installed (`addonInstalled: false`)

The addon needs to be installed manually. Follow these steps:

**Manual Installation Steps**:

**Method 1: Install from ZIP (Recommended)**
```bash
# 1. Open Blender 4.0+
# 2. Edit > Preferences > Add-ons > Install
# 3. Select: .blender-toolkit/blender-toolkit-addon-v*.zip
# 4. Enable "Blender Toolkit WebSocket Server"
```

**Method 2: Install from Source**
```bash
# 1. Open Blender 4.0+
# 2. Edit > Preferences > Add-ons > Install
# 3. Select: plugins/blender-toolkit/skills/addon/__init__.py
# 4. Enable "Blender Toolkit WebSocket Server"
```

**Start WebSocket Server**:
1. Open 3D View → Sidebar (press N key)
2. Find "Blender Toolkit" tab
3. Click "Start Server" button
4. Default port: 9400 (auto-assigned per project)

**Update Config**:
- Open config file (path shown above)
- Set `"addonInstalled": true`
- Save file

**Verify Connection**:
- Try a simple command: `node .blender-toolkit/bt.js list-objects`
- If successful, you'll see a list of objects in your scene

**Troubleshooting**:
- If Blender path is incorrect: Update `blenderExecutable` in config
- If port is in use: System will auto-assign next available port (9401-9500)
- Check logs: `.blender-toolkit/init-log.txt`
- Check Blender console for error messages

### 4. If Everything is Ready (`addonInstalled: true`)

✅ You're all set! You can use all Blender Toolkit commands.

---

# blender-toolkit

Automate Blender workflows with WebSocket-based real-time control. Create geometry, manage materials and modifiers, and retarget Mixamo animations to custom rigs with intelligent bone mapping.

## Purpose

Provide comprehensive Blender automation through:
- 🎨 **Geometry Creation** - Primitives (cube, sphere, cylinder, plane, cone, torus)
- 🎭 **Material Management** - Create, assign, and configure materials
- 🔧 **Modifier Control** - Add, apply, and manage modifiers
- 🎬 **Animation Retargeting** - Mixamo to custom rigs with automatic bone mapping

## When to Use

Use this skill when:
- **Creating 3D Geometry:** User wants to create primitives or manipulate meshes
- **Managing Materials:** User needs to create or assign materials with PBR properties
- **Adding Modifiers:** User wants subdivision, mirror, array, or other modifiers
- **Retargeting Animations:** User needs to apply Mixamo animations to custom characters
- **Batch Operations:** User wants to process multiple objects or animations

**Note:** Mixamo does not provide an official API. Users must manually download FBX files from Mixamo.com.

## Quick Start

### Prerequisites Checklist

Before starting, ensure:
- [ ] Blender 4.0+ installed
- [ ] Blender Toolkit addon installed and enabled
- [ ] WebSocket server started in Blender (default port: 9400)
- [ ] Character rig loaded (for animation retargeting)

**Install Addon:**
```
1. Open Blender → Edit → Preferences → Add-ons
2. Click "Install" → Select plugins/blender-toolkit/skills/addon/__init__.py
3. Enable "Blender Toolkit WebSocket Server"
4. Start server: View3D → Sidebar (N) → "Blender Toolkit" → "Start Server"
```

### Common Operations

**Create Geometry:**
```bash
# Create cube at origin
blender-toolkit create-cube --size 2.0

# Create sphere with custom settings
blender-toolkit create-sphere --radius 1.5 --segments 64

# Subdivide mesh
blender-toolkit subdivide --name "Cube" --cuts 2
```

**Manage Objects:**
```bash
# List all objects
blender-toolkit list-objects

# Transform object
blender-toolkit transform --name "Cube" --loc-x 5 --loc-y 0 --scale-x 2

# Duplicate object
blender-toolkit duplicate --name "Cube" --new-name "Cube.001" --x 3
```

**Materials:**
```bash
# Create material
blender-toolkit material create --name "RedMaterial"

# Assign to object
blender-toolkit material assign --object "Cube" --material "RedMaterial"

# Set color
blender-toolkit material set-color --material "RedMaterial" --r 1.0 --g 0.0 --b 0.0
```

**Retarget Animation:**
```bash
# Basic retargeting with UI confirmation
blender-toolkit retarget \
  --target "HeroRig" \
  --file "./Walking.fbx" \
  --name "Walking"

# Rigify preset (skip confirmation)
blender-toolkit retarget \
  --target "MyRigifyCharacter" \
  --file "./Walking.fbx" \
  --mapping mixamo_to_rigify \
  --skip-confirmation

# Show Mixamo download instructions
blender-toolkit mixamo-help Walking
```

## Architecture

**WebSocket-Based Design:**

```
┌──────────────┐         ┌─────────────┐    WebSocket    ┌──────────────┐
│ Claude Code  │   IPC   │ TypeScript  │◄──────────────►│   Blender    │
│   (Skill)    │────────►│   Client    │   Port 9400+   │  (Addon)     │
└──────────────┘         └─────────────┘                └──────────────┘
                              │                               │
                              ▼                               ▼
                     ┌─────────────────┐         ┌────────────────────┐
                     │  - Geometry     │         │  - WebSocket       │
                     │  - Material     │         │    Server          │
                     │  - Modifier     │         │  - Command         │
                     │  - Retargeting  │         │    Handlers        │
                     │  - Bone Mapping │         │  - Bone Mapping UI │
                     └─────────────────┘         └────────────────────┘
```

**Key Components:**
- **WebSocket Server:** Python addon in Blender (ports 9400-9500)
- **TypeScript Client:** Sends commands via JSON-RPC
- **Bone Mapping System:** Fuzzy matching with UI confirmation
- **Two-Phase Workflow:** Generate → Review → Apply

## Core Workflows

### 1. Geometry Creation Workflow

**Extract Requirements:**
- Primitive type (cube, sphere, cylinder, etc.)
- Position (x, y, z coordinates)
- Size parameters (radius, depth, segments)
- Optional object name

**Execute:**
```typescript
import { BlenderClient } from 'blender-toolkit';

const client = new BlenderClient();
await client.connect(9400);

// Create sphere
const result = await client.sendCommand('Geometry.createSphere', {
  location: [0, 0, 2],
  radius: 1.5,
  segments: 64,
  name: 'MySphere'
});

console.log(`✅ Created ${result.name} with ${result.vertices} vertices`);
```

### 2. Material Assignment Workflow

**Steps:**
1. Create material
2. Assign to object
3. Configure properties (color, metallic, roughness)

**Execute:**
```bash
# Create and configure material
blender-toolkit material create --name "Metal"
blender-toolkit material set-color --material "Metal" --r 0.8 --g 0.8 --b 0.8
blender-toolkit material set-metallic --material "Metal" --value 1.0
blender-toolkit material set-roughness --material "Metal" --value 0.2

# Assign to object
blender-toolkit material assign --object "Sphere" --material "Metal"
```

### 3. Animation Retargeting Workflow ⭐

**Most Common Use Case**

**Phase 1: Setup & Generate Mapping**
```
1. User provides:
   - Target character armature name
   - Animation FBX file path
   - (Optional) Animation name for NLA track

2. System executes:
   - Connects to Blender WebSocket
   - Imports FBX file
   - Analyzes bone structure
   - Auto-generates bone mapping (fuzzy matching)
   - Displays mapping in Blender UI for review

3. Quality Assessment:
   - Excellent (8-9 critical bones) → Safe to auto-apply
   - Good (6-7 critical bones) → Quick review recommended
   - Fair (4-5 critical bones) → Thorough review required
   - Poor (< 4 critical bones) → Manual mapping needed
```

**Phase 2: User Confirmation**
```
1. User reviews mapping in Blender:
   - View3D → Sidebar (N) → "Blender Toolkit" → "Bone Mapping Review"
   - Check source → target correspondence
   - Edit incorrect mappings using dropdowns
   - Use "Auto Re-map" button to regenerate if needed

2. User confirms:
   - Click "Apply Retargeting" button in Blender

3. System completes:
   - Creates constraint-based retargeting
   - Bakes animation to keyframes
   - Adds to NLA track
   - Cleans up temporary objects
```

**Example:**
```typescript
import { AnimationRetargetingWorkflow } from 'blender-toolkit';

const workflow = new AnimationRetargetingWorkflow();

// If user doesn't have FBX yet
console.log(workflow.getManualDownloadInstructions('Walking'));

// After user downloads FBX
await workflow.run({
  targetCharacterArmature: 'HeroRig',
  animationFilePath: './Walking.fbx',
  animationName: 'Walking',
  boneMapping: 'auto',           // Auto-generate with fuzzy matching
  skipConfirmation: false        // Enable UI review workflow
});
```

**Skip Confirmation (For Known-Good Mappings):**
```bash
# Rigify preset - instant application
blender-toolkit retarget \
  --target "RigifyCharacter" \
  --file "./Walking.fbx" \
  --mapping mixamo_to_rigify \
  --skip-confirmation

# Excellent quality - trusted auto-mapping
blender-toolkit retarget \
  --target "MyCharacter" \
  --file "./Walking.fbx" \
  --skip-confirmation
```

## Key Features

### Auto Bone Mapping with UI Review 🌟

**Recommended Workflow** for unknown or custom rigs:

**How It Works:**
1. **Fuzzy Matching Algorithm**
   - Normalizes bone names (handles various conventions)
   - Calculates similarity scores (0.0-1.0)
   - Applies bonuses for:
     - Substring matches (+0.15)
     - Common prefixes: left, right (+0.1)
     - Common suffixes: .L, .R, _l, _r (+0.1)
     - Number matching: Spine1, Spine2 (+0.1)
     - Anatomical keywords: arm, leg, hand (+0.05)

2. **Quality Assessment**
   - Tracks 9 critical bones (Hips, Spine, Head, Arms, Legs, Hands)
   - Provides quality rating (Excellent/Good/Fair/Poor)
   - Recommends action based on quality

3. **UI Confirmation Panel**
   - Shows complete mapping table
   - Editable dropdowns for each mapping
   - "Auto Re-map" button (regenerate)
   - "Apply Retargeting" button (proceed)

**Benefits:**
- Works with any rig structure
- No manual configuration needed
- User verifies before application
- Prevents animation errors

### Three Bone Mapping Modes

**1. Auto Mode (Recommended)** ⭐
```bash
# Default: Auto-generate with UI confirmation
blender-toolkit retarget --target "Hero" --file "./Walk.fbx"
```
- Fuzzy matching algorithm
- UI review workflow
- Best for unknown rigs

**2. Rigify Mode**
```bash
# Preset for Rigify control rigs
blender-toolkit retarget --target "Hero" --file "./Walk.fbx" --mapping mixamo_to_rigify
```
- Predefined Mixamo → Rigify mapping
- Instant application
- Highest accuracy for Rigify

**3. Custom Mode**
```typescript
// Explicit bone mapping
const customMapping = {
  "Hips": "root_bone",
  "Spine": "torso_01",
  "LeftArm": "l_upper_arm",
  // ... complete mapping
};

await workflow.run({
  boneMapping: customMapping,
  skipConfirmation: true
});
```
- Full control
- Reusable across animations
- For non-standard rigs

### Multi-Project Support

**Automatic Port Management:**
- Projects automatically assigned unique ports (9400-9500)
- Configuration persists across sessions
- Multiple Blender instances can run simultaneously

**Configuration Storage:**
```json
// ~/.claude/plugins/.../blender-config.json
{
  "projects": {
    "/path/to/project-a": { "port": 9400 },
    "/path/to/project-b": { "port": 9401 }
  }
}
```

## Important Guidelines

### When to Ask User

Use `AskUserQuestion` tool if:
- Character armature name is unclear
- Multiple rigs exist (ambiguous target)
- Animation FBX path not provided
- Blender WebSocket connection fails
- User needs Mixamo download guidance

**DO NOT** guess:
- Character names
- File paths
- Rig structures

### Mixamo Download Process

Since Mixamo has no API, users must manually download:

**Provide Instructions:**
```typescript
// Show download help
const workflow = new AnimationRetargetingWorkflow();
console.log(workflow.getManualDownloadInstructions('Walking'));
console.log(workflow.getRecommendedSettings());
```

**Wait for User:**
- Guide user through Mixamo.com download
- Get file path after download completes
- Then proceed with retargeting

## Troubleshooting

### "Blender is not running"
```bash
# Check connection
blender-toolkit daemon-status

# If failed:
1. Verify Blender is open
2. Check addon is enabled
3. Start server: Blender → N → "Blender Toolkit" → "Start Server"
```

### "Target armature not found"
- Verify exact armature name (case-sensitive)
- Check character is in current scene
- Use `list-objects --type ARMATURE` to see available armatures

### "Poor quality" bone mapping
1. Review bone names in Blender (Edit Mode)
2. Create custom mapping for critical bones
3. Lower similarity threshold (default: 0.6)
4. Check rig has proper hierarchy

### "Twisted or inverted limbs"
- Check left/right bone mapping
- Verify bone roll in Edit Mode
- Review constraint axes
- Test with simple animation first

## Best Practices

1. **🌟 Use Auto Mode with UI Confirmation**
   - Most reliable for unknown rigs
   - Always review critical bones (Hips, Spine, Arms, Legs)
   - Edit incorrect mappings before applying

2. **Test Simple Animations First**
   - Start with Idle or Walking
   - Verify bone mapping works correctly
   - Check root motion (Hips bone)
   - Then proceed to complex animations

3. **Download Correct Format from Mixamo**
   - Format: FBX (.fbx)
   - Skin: Without Skin
   - FPS: 30 fps
   - Keyframe Reduction: None

4. **Check Quality Before Auto-Apply**
   - Excellent (8-9 critical) → Safe to skip confirmation
   - Good (6-7 critical) → Quick review
   - Fair (4-5 critical) → Thorough review
   - Poor (< 4 critical) → Use custom mapping

5. **Save Custom Mappings for Reuse**
   - Document successful mappings
   - Reuse for same character's animations
   - Share with team members

6. **Let System Manage Ports**
   - Don't manually configure ports
   - System handles multi-project conflicts
   - Configuration persists automatically

## References

Detailed documentation in `references/` folder:

- **[commands-reference.md](references/commands-reference.md)** - Complete CLI command reference
  - All geometry, object, material, modifier commands
  - Detailed options and examples
  - Port management and tips

- **[bone-mapping-guide.md](references/bone-mapping-guide.md)** - Bone matching system details
  - Fuzzy matching algorithm explained
  - Quality assessment metrics
  - Common mapping patterns (Rigify, UE4, Unity)
  - Troubleshooting mapping issues

- **[workflow-guide.md](references/workflow-guide.md)** - Complete workflow documentation
  - Step-by-step retargeting workflow
  - Mixamo download process
  - Two-phase confirmation details
  - Batch processing workflows
  - Multi-project workflows

- **[addon-api-reference.md](references/addon-api-reference.md)** - WebSocket API documentation
  - JSON-RPC protocol details
  - All API methods and parameters
  - Error handling
  - Security and performance tips

**When to Load References:**
- User needs detailed command options
- Troubleshooting complex issues
- Understanding bone mapping algorithm
- Setting up advanced workflows
- API integration requirements

## Output Structure

```
.blender-toolkit/
├── skills/scripts/          # Local TypeScript scripts (auto-initialized)
│   ├── src/                 # Source code
│   ├── dist/                # Compiled JavaScript
│   └── node_modules/        # Dependencies
├── bt.js                    # CLI wrapper
├── logs/                    # Log files
│   ├── typescript.log
│   ├── blender-addon.log
│   └── error.log
└── .gitignore

Shared config:
~/.claude/plugins/.../blender-config.json
```

## Notes

- **Port range:** 9400-9500 (Browser Pilot uses 9222-9322)
- **File formats:** FBX recommended, Collada (.dae) supported
- **Blender version:** 4.0+ required (2023+)
- **Auto-initialization:** SessionStart hook installs and builds scripts
- **No manual daemon management:** System handles everything
- **WebSocket protocol:** JSON-RPC 2.0
