import * as THREE from "three/webgpu";
import { PointCloud, DynamicPointCloud } from "../point_cloud";
import { mat4, vec3 } from "gl-matrix";
import { ModelEntry, ModelType } from "../models/model-entry";
import { FBXModelWrapper } from "../models/fbx-model-wrapper";
import { Aabb } from "../utils";

/**
 * GaussianModel - View layer for Gaussian Splat models
 * 
 * Extends THREE.Object3D to integrate Gaussian models into Three.js scene graph.
 * Responsibilities:
 * 1. THREE.Object3D - Manages TRS (position, rotation, scale) and scene hierarchy
 * 2. Holds PointCloud data (via ModelEntry)
 * 3. Syncs transform to rendering pipeline
 * 4. Handles dynamic model updates
 * 
 * Note: Loading logic has been moved to GaussianLoader service (managers layer)
 */
export class GaussianModel extends THREE.Object3D {
    private mEntry: ModelEntry;
    private autoSyncEnabled: boolean = true;
    private _overrideLocalAabb: Aabb | null = null; // 手动覆盖的局部 AABB（优先级最高）
    private _cachedWorldAabb: Aabb | null = null;   // 缓存的世界 AABB
    private _worldAabbDirty: boolean = true;        // 变换或覆盖变化后置脏
    
    // 高斯点缩放参数（独立于Three.js的scale属性）
    private _gaussianScale: number = 1.0;

    /**
     * Create a GaussianModel from a ModelEntry
     * @param entry - Model data entry containing PointCloud
     */
    constructor(entry: ModelEntry) {
        super();
        this.mEntry = entry;
        this.name = entry.name;
        
        // Enable auto-sync when Object3D transform properties change
        this.setupAutoSync();
    }

    /**
     * Setup automatic synchronization of Object3D transform to GPU
     * This works by monitoring matrix updates and common transform operations
     * @private
     */
    private setupAutoSync(): void {
        // Track if sync is needed (avoid unnecessary GPU updates)
        let syncPending = false;
        let lastMatrixUpdate = Date.now();
        
        // Function to schedule GPU sync
        const scheduleSync = () => {
            if (this.autoSyncEnabled && !syncPending) {
                syncPending = true;
                // Use requestAnimationFrame to batch updates
                requestAnimationFrame(() => {
                    this.syncTransformToGPU();
                    this._worldAabbDirty = true; // 变换改变，世界包围盒失效
                    syncPending = false;
                });
            }
        };
        
        // Store original updateMatrix method
        const originalUpdateMatrix = this.updateMatrix.bind(this);
        
        // Override updateMatrix to detect changes
        this.updateMatrix = () => {
            originalUpdateMatrix();
            
            // Check if matrix actually changed (avoid excessive syncs)
            const now = Date.now();
            if (now - lastMatrixUpdate > 8) { // Throttle to ~120fps max
                lastMatrixUpdate = now;
                scheduleSync();
            }
        };
        
        // Force matrix auto-update
        this.matrixAutoUpdate = true;
        
        // Intercept common transform methods on position, rotation, scale
        this.interceptTransformMethods(scheduleSync);
        
        console.log(`✅ Auto-sync setup for model: ${this.name}`);
    }

    /**
     * Intercept common transform methods to trigger immediate sync
     * @private
     */
    private interceptTransformMethods(scheduleSync: () => void): void {
        // Intercept Vector3.set methods
        const originalPositionSet = this.position.set.bind(this.position);
        const originalScaleSet = this.scale.set.bind(this.scale);
        const originalRotationSet = this.rotation.set.bind(this.rotation);
        
        // Position.set()
        this.position.set = (x: number, y: number, z: number) => {
            const result = originalPositionSet(x, y, z);
            scheduleSync();
            return result;
        };
        
        // Scale.set()
        this.scale.set = (x: number, y: number, z: number) => {
            const result = originalScaleSet(x, y, z);
            scheduleSync();
            return result;
        };
        
        // Rotation.set()
        this.rotation.set = (x: number, y: number, z: number, order?: THREE.EulerOrder) => {
            const result = originalRotationSet(x, y, z, order);
            scheduleSync();
            return result;
        };
    }

    // ============ Getters ============
    
    /**
     * Get model ID (note: different from Object3D.id which is a number)
     */
    public getModelId(): string {
        return this.mEntry.id;
    }
    
    public get modelName(): string {
        return this.mEntry.name;
    }
    
    public get pointCount(): number {
        return this.mEntry.pointCount;
    }
    
    public get isDynamic(): boolean {
        return this.mEntry.isDynamic;
    }
    
    public get modelType(): ModelType {
        return this.mEntry.modelType;
    }
    
    /**
     * Get the underlying ModelEntry (data layer access)
     */
    public getEntry(): ModelEntry {
        return this.mEntry;
    }
    
    /**
     * Get the PointCloud instance
     */
    public getPointCloud(): PointCloud | DynamicPointCloud | FBXModelWrapper {
        if (!this.mEntry?.pointCloud) {
            throw new Error("PointCloud is not initialized");
        }
        return this.mEntry.pointCloud;
    }

    /**
     * Check if the model is a Gaussian model (PointCloud or DynamicPointCloud)
     * @returns True if model is PointCloud or DynamicPointCloud, false if FBX
     */
    private isGaussianModel(): boolean {
        const pc = this.mEntry.pointCloud;
        return pc instanceof PointCloud || pc instanceof DynamicPointCloud;
    }

    // ============ Transform Management ============

    /**
     * Get current transform matrix from Object3D TRS
     * @returns 4x4 column-major transform matrix
     */
    public getTransformMatrix(): Float32Array {
        const matrix = new THREE.Matrix4();
        matrix.compose(this.position, this.quaternion, this.scale);
        const opencvCorrection = new THREE.Matrix4().makeScale(1, -1, -1);
        opencvCorrection.premultiply(matrix);
        // opencvCorrection.multiply(opencvCorrection);
        return new Float32Array(opencvCorrection.elements);
    }

    /**
     * Sync Object3D transform to PointCloud GPU buffer
     * Call this after modifying position/rotation/scale
     * @param baseOffset - Base offset in global buffer (for multi-model rendering)
     */
    public syncTransformToGPU(baseOffset: number = 0): void {
        if (!this.mEntry?.pointCloud) return;

        const transform = this.getTransformMatrix();
        
        // 更新PointCloud的transform属性（渲染器会使用这个）
        this.mEntry.pointCloud.setTransform(transform);
        
        // 更新GPU缓冲区（仅高斯模型）
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            gaussianModel.updateModelParamsBuffer(transform, baseOffset);
        }
        
        if ((globalThis as any).GS_DEBUG_FLAG) {
            console.log(`[GaussianModel] Synced transform for ${this.name}:`, {
                position: [this.position.x.toFixed(3), this.position.y.toFixed(3), this.position.z.toFixed(3)],
                rotation: [this.rotation.x.toFixed(3), this.rotation.y.toFixed(3), this.rotation.z.toFixed(3)],
                scale: [this.scale.x.toFixed(3), this.scale.y.toFixed(3), this.scale.z.toFixed(3)]
            });
        }
    }

    // ============ AABB（包围盒） ============

    /**
     * 设置（或清除）局部空间 AABB 覆盖值。
     * 传入 null 可清除覆盖（恢复为自动/估计）。
     */
    public setOverrideAABB(aabb: { min: [number, number, number]; max: [number, number, number]; } | Aabb | null): void {
        if (aabb === null) {
            this._overrideLocalAabb = null;
        } else if (aabb instanceof Aabb) {
            this._overrideLocalAabb = aabb;
        } else {
            const minV = vec3.fromValues(aabb.min[0], aabb.min[1], aabb.min[2]);
            const maxV = vec3.fromValues(aabb.max[0], aabb.max[1], aabb.max[2]);
            this._overrideLocalAabb = new Aabb(minV, maxV);
        }
        this._worldAabbDirty = true;
    }

    /**
     * 获取局部空间 AABB。
     * 优先使用覆盖值；否则读取底层 PointCloud 的 bbox（静态 PLY 准确，动态 ONNX 为保守/默认）。
     */
    public getLocalAABB(): Aabb | null {
        if (this._overrideLocalAabb) return this._overrideLocalAabb;
        const pc = this.mEntry?.pointCloud as any;
        if (pc && pc.bbox instanceof Aabb) return pc.bbox as Aabb;
        return null;
    }

    /**
     * 计算并返回世界空间 AABB（一次性缓存，变换或覆盖更新后置脏重算）。
     */
    public getWorldAABB(): Aabb | null {
        const local = this.getLocalAABB();
        if (!local) return null;
        if (this._cachedWorldAabb && !this._worldAabbDirty) return this._cachedWorldAabb;

        // 构造 8 个角点（局部），用当前 Object3D 的世界矩阵变换后取 min/max
        const minL = local.min;
        const maxL = local.max;
        const corners: [number, number, number][] = [
            [minL[0], minL[1], minL[2]],
            [minL[0], minL[1], maxL[2]],
            [minL[0], maxL[1], minL[2]],
            [minL[0], maxL[1], maxL[2]],
            [maxL[0], minL[1], minL[2]],
            [maxL[0], minL[1], maxL[2]],
            [maxL[0], maxL[1], minL[2]],
            [maxL[0], maxL[1], maxL[2]],
        ];

        const mat = new THREE.Matrix4();
        mat.compose(this.position, this.quaternion, this.scale);

        const tmp = new THREE.Vector3();
        const minW = vec3.fromValues(+Infinity, +Infinity, +Infinity);
        const maxW = vec3.fromValues(-Infinity, -Infinity, -Infinity);
        for (const c of corners) {
            tmp.set(c[0], c[1], c[2]).applyMatrix4(mat);
            if (tmp.x < minW[0]) minW[0] = tmp.x; if (tmp.y < minW[1]) minW[1] = tmp.y; if (tmp.z < minW[2]) minW[2] = tmp.z;
            if (tmp.x > maxW[0]) maxW[0] = tmp.x; if (tmp.y > maxW[1]) maxW[1] = tmp.y; if (tmp.z > maxW[2]) maxW[2] = tmp.z;
        }
        this._cachedWorldAabb = new Aabb(minW, maxW);
        this._worldAabbDirty = false;
        return this._cachedWorldAabb;
    }

    // ============ Dynamic Update ============

    /**
     * Update dynamic model (ONNX) with camera matrices
     * Transform is dynamically obtained from Object3D and passed to PointCloud
     * @param cameraMatrix - Camera view matrix
     * @param time - Optional time parameter for animation
     * @param projectionMatrix - Optional projection matrix
     */
    public async update(cameraMatrix: mat4, time?: number, projectionMatrix?: mat4): Promise<void> {
        if (!(this.mEntry?.pointCloud instanceof DynamicPointCloud)) {
            return;
        }

        // Dynamically get current transform from Object3D
        const transform = this.getTransformMatrix();
        
        // Pass transform to DynamicPointCloud for ONNX inference
        // 阻塞等待推理完成
        await this.mEntry.pointCloud.update(cameraMatrix, transform, time || 0, projectionMatrix);
    }

    // ============ Visibility ============

    /**
     * Set model visibility (syncs both Object3D.visible and ModelEntry.visible)
     */
    public setModelVisible(value: boolean): void {
        this.visible = value; // Object3D.visible
        if (this.mEntry) this.mEntry.visible = value;
    }

    /**
     * Get model visibility (checks both Object3D and ModelEntry)
     */
    public getModelVisible(): boolean {
        // Prioritize Object3D.visible as it's the source of truth for rendering
        return this.visible;
    }

    /**
     * Check if model is visible from camera (for frustum culling)
     * Currently always returns true - can be enhanced with proper frustum culling
     */
    public isVisible(camera: THREE.Camera): boolean {
        // Simple check: if Object3D is visible, it's visible
        // We can add frustum culling here later if needed
        return this.visible;
    }

    // ============ Auto-Sync Control ============

    /**
     * Enable or disable automatic GPU synchronization
     * When enabled, changes to position/rotation/scale automatically sync to GPU
     * @param enabled - Whether to enable auto-sync
     */
    public setAutoSync(enabled: boolean): void {
        this.autoSyncEnabled = enabled;
        console.log(`Auto-sync ${enabled ? 'enabled' : 'disabled'} for model: ${this.modelName}`);
    }

    /**
     * Check if auto-sync is enabled
     */
    public getAutoSync(): boolean {
        return this.autoSyncEnabled;
    }

    /**
     * Force immediate synchronization to GPU (regardless of auto-sync setting)
     */
    public forceSyncToGPU(): void {
        this.syncTransformToGPU();
    }

    /**
     * Dispose resources and cleanup
     * Call this when the model is no longer needed
     * Note: Proxy interceptions will be cleaned up when object is garbage collected
     */
    public dispose(): void {
        // Disable auto-sync
        this.autoSyncEnabled = false;
        
        console.log(`🧹 GaussianModel disposed: ${this.modelName}`);
    }

    // ============ Deprecated Methods ============
    
    /**
     * @deprecated Use setTransform from external PointCloud methods
     * This method is kept for backward compatibility
     */
    public setTransform(transform: Float32Array, baseOffset: number = 0): void {
        console.warn('GaussianModel.setTransform() is deprecated. Modify position/rotation/scale instead.');
        this.mEntry.pointCloud.setTransform(transform);
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            gaussianModel.updateModelParamsBuffer(transform, baseOffset);
        }
    }
    
    // ============ Gaussian Scaling ============
    
    /**
     * Set Gaussian scaling parameter (independent of Three.js scale)
     * @param scale - Scaling factor for Gaussian points
     */
    public setGaussianScale(scale: number): void {
        this._gaussianScale = scale;
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            gaussianModel.setGaussianScaling(scale);
            console.log(`[GaussianModel] ${this.name} Gaussian scale set to: ${scale}`);
        }
    }
    
    /**
     * Get current Gaussian scaling parameter
     * @returns Current Gaussian scale value
     */
    public getGaussianScale(): number {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            return gaussianModel.getGaussianScaling();
        }
        return this._gaussianScale;
    }

    /**
     * Set maximum spherical harmonics degree
     * @param deg - Maximum SH degree (0-3)
     */
    public setMaxShDeg(deg: number): void {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            gaussianModel.setMaxShDeg(deg);
            console.log(`[GaussianModel] ${this.name} Max SH degree set to: ${deg}`);
        }
    }
    
    /**
     * Get current maximum spherical harmonics degree
     * @returns Current max SH degree
     */
    public getMaxShDeg(): number {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            return gaussianModel.getMaxShDeg();
        }
        return 0;
    }

    /**
     * Set kernel size for 2D splatting
     * @param size - Kernel size
     */
    public setKernelSize(size: number): void {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            gaussianModel.setKernelSize(size);
            console.log(`[GaussianModel] ${this.name} Kernel size set to: ${size}`);
        }
    }
    
    /**
     * Get current kernel size
     * @returns Current kernel size
     */
    public getKernelSize(): number {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            return gaussianModel.getKernelSize();
        }
        return 0;
    }

    /**
     * Set opacity scale factor
     * @param scale - Opacity scale factor
     */
    public setOpacityScale(scale: number): void {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            gaussianModel.setOpacityScale(scale);
            console.log(`[GaussianModel] ${this.name} Opacity scale set to: ${scale}`);
        }
    }
    
    /**
     * Get current opacity scale factor
     * @returns Current opacity scale factor
     */
    public getOpacityScale(): number {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            return gaussianModel.getOpacityScale();
        }
        return 1.0;
    }

    /**
     * Set cutoff scale factor for pixel ratio
     * @param scale - Cutoff scale factor
     */
    public setCutoffScale(scale: number): void {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            gaussianModel.setCutoffScale(scale);
            console.log(`[GaussianModel] ${this.name} Cutoff scale set to: ${scale}`);
        }
    }
    
    /**
     * Get current cutoff scale factor
     * @returns Current cutoff scale factor
     */
    public getCutoffScale(): number {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            return gaussianModel.getCutoffScale();
        }
        return 1.0;
    }

    /**
     * Set time scale factor for dynamic models
     * @param scale - Time scale factor
     */
    public setTimeScale(scale: number): void {
        if (this.mEntry.pointCloud && 'setTimeScale' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).setTimeScale(scale);
            console.log(`[GaussianModel] ${this.name} Time scale set to: ${scale}`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support time scale (not a dynamic model)`);
        }
    }
    
    /**
     * Get current time scale factor
     * @returns Current time scale factor
     */
    public getTimeScale(): number {
        if (this.mEntry.pointCloud && 'getTimeScale' in this.mEntry.pointCloud) {
            return (this.mEntry.pointCloud as any).getTimeScale();
        }
        return 1.0; // Default for non-dynamic models
    }

    /**
     * Set time offset for dynamic models
     * @param offset - Time offset in seconds
     */
    public setTimeOffset(offset: number): void {
        if (this.mEntry.pointCloud && 'setTimeOffset' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).setTimeOffset(offset);
            console.log(`[GaussianModel] ${this.name} Time offset set to: ${offset}`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support time offset (not a dynamic model)`);
        }
    }
    
    /**
     * Set time offset for dynamic models
     * @param offset - Time offset in seconds
     */
    public setAnimationIsLoop(begin_loop: boolean): void {
        if (this.mEntry.pointCloud && 'setAnimationIsLoop' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).setAnimationIsLoop(begin_loop);
            console.log(`[GaussianModel] ${this.name} Is Loop set to: ${begin_loop}`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support animation is loop (not a dynamic model)`);
        }
    }

    /**
     * Get current time offset
     * @returns Current time offset
     */
    public getTimeOffset(): number {
        if (this.mEntry.pointCloud && 'getTimeOffset' in this.mEntry.pointCloud) {
            return (this.mEntry.pointCloud as any).getTimeOffset();
        }
        return 0.0; // Default for non-dynamic models
    }

    /**
     * Set time update mode for dynamic models
     * @param mode - Time update mode
     */
    public setTimeUpdateMode(mode: any): void {
        if (this.mEntry.pointCloud && 'setTimeUpdateMode' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).setTimeUpdateMode(mode);
            console.log(`[GaussianModel] ${this.name} Time update mode set to: ${mode}`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support time update mode (not a dynamic model)`);
        }
    }

    /**
     * Set render mode for the model
     * @param mode - Render mode (0=color, 1=normal, 2=depth)
     */
    public setRenderMode(mode: number): void {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as PointCloud | DynamicPointCloud;
            gaussianModel.setRenderMode(mode);
            console.log(`[GaussianModel] ${this.name} Render mode set to: ${mode}`);
        }
    }
    
    /** Get current render mode */
    public getRenderMode(): number {
        if (this.isGaussianModel()) {
            const gaussianModel = this.mEntry.pointCloud as any;
            if (typeof gaussianModel.getRenderMode === 'function') {
                return gaussianModel.getRenderMode();
            }
        }
        return 0;
    }
    
    /**
     * Get current time update mode
     * @returns Current time update mode
     */
    public getTimeUpdateMode(): any {
        if (this.mEntry.pointCloud && 'getTimeUpdateMode' in this.mEntry.pointCloud) {
            return (this.mEntry.pointCloud as any).getTimeUpdateMode();
        }
        return 'fixed_delta'; // Default for non-dynamic models
    }

    /**
     * Start animation for dynamic models
     * @param speed - Animation speed multiplier
     */
    public startAnimation(speed: number = 1.0): void {
        if (this.mEntry.pointCloud && 'startAnimation' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).startAnimation(speed);
            console.log(`[GaussianModel] ${this.name} Animation started at ${speed}x speed`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support animation (not a dynamic model)`);
        }
    }

    /**
     * Pause animation for dynamic models
     */
    public pauseAnimation(): void {
        if (this.mEntry.pointCloud && 'pauseAnimation' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).pauseAnimation();
            console.log(`[GaussianModel] ${this.name} Animation paused`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support animation (not a dynamic model)`);
        }
    }

    /**
     * Resume animation for dynamic models
     */
    public resumeAnimation(): void {
        if (this.mEntry.pointCloud && 'resumeAnimation' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).resumeAnimation();
            console.log(`[GaussianModel] ${this.name} Animation resumed`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support animation (not a dynamic model)`);
        }
    }

    /**
     * Stop animation for dynamic models
     */
    public stopAnimation(): void {
        if (this.mEntry.pointCloud && 'stopAnimation' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).stopAnimation();
            console.log(`[GaussianModel] ${this.name} Animation stopped`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support animation (not a dynamic model)`);
        }
    }

    /**
     * Set animation time for dynamic models
     * @param time - Animation time in seconds
     */
    public setAnimationTime(time: number): void {
        if (this.mEntry.pointCloud && 'setAnimationTime' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).setAnimationTime(time);
            console.log(`[GaussianModel] ${this.name} Animation time set to ${time.toFixed(3)}s`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support animation (not a dynamic model)`);
        }
    }

    /**
     * Set animation speed for dynamic models
     * @param speed - Animation speed multiplier
     */
    public setAnimationSpeed(speed: number): void {
        if (this.mEntry.pointCloud && 'setAnimationSpeed' in this.mEntry.pointCloud) {
            (this.mEntry.pointCloud as any).setAnimationSpeed(speed);
            console.log(`[GaussianModel] ${this.name} Animation speed set to ${speed}x`);
        } else {
            console.warn(`[GaussianModel] ${this.name} does not support animation (not a dynamic model)`);
        }
    }

    /**
     * Get animation speed for dynamic models
     * @returns Current animation speed
     */
    public getAnimationSpeed(): number {
        if (this.mEntry.pointCloud && 'getAnimationSpeed' in this.mEntry.pointCloud) {
            return (this.mEntry.pointCloud as any).getAnimationSpeed();
        }
        return 1.0; // Default for non-dynamic models
    }

    /**
     * Check if animation is running for dynamic models
     * @returns True if animation is running
     */
    public isAnimationRunning(): boolean {
        if (this.mEntry.pointCloud && 'isAnimationRunning' in this.mEntry.pointCloud) {
            return (this.mEntry.pointCloud as any).isAnimationRunning;
        }
        return false; // Default for non-dynamic models
    }

    /**
     * Check if animation is paused for dynamic models
     * @returns True if animation is paused
     */
    public isAnimationPaused(): boolean {
        if (this.mEntry.pointCloud && 'isAnimationPaused' in this.mEntry.pointCloud) {
            return (this.mEntry.pointCloud as any).isAnimationPaused;
        }
        return false; // Default for non-dynamic models
    }
}
