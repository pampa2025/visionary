import React, { createContext, useContext } from 'react';
import { GaussianThreeJSRenderer } from '../visionary-core-copy/app/GaussianThreeJSRenderer';
import { GaussianLoader } from '../visionary-core-copy/app/managers/gaussian-loader';
import { ModelManager } from '../visionary-core-copy/app/managers/model-manager';

interface VisionaryContextType {
    renderer: GaussianThreeJSRenderer | null;
    gaussianLoader: GaussianLoader | null;
    modelManager: ModelManager | null;
    isReady: boolean;
}

const VisionaryContext = createContext<VisionaryContextType>({
    renderer: null,
    gaussianLoader: null,
    modelManager: null,
    isReady: false,
});

export const useVisionary = () => useContext(VisionaryContext);

export const VisionaryProvider = VisionaryContext.Provider;
