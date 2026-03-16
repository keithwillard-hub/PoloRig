/*
 * Copyright ©️ 2024 Sebastian Delmont <sd@ham2k.com>
 *
 * This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
 * If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import { createSlice } from '@reduxjs/toolkit'

const INITIAL_STATE = {
  status: 'ready',
  files: {}
}

export const dataFilesSlice = createSlice({
  name: 'dataFiles',

  initialState: INITIAL_STATE,

  reducers: {
    setDataFileInfo: (state, action) => {
      state.files[action.payload.key] = { ...state.files[action.payload.key], ...action.payload }
    },
    unsetDataFileInfo: (state, action) => {
      state.files[action.payload.key] = undefined
      delete state.files[action.payload.key]
    }
  }
})

export const { actions } = dataFilesSlice

export const selectDataFileInfo = (state, key) => state?.dataFiles?.files?.[key]

export const selectAllDataFileInfos = (state) => state?.dataFiles?.files

export default dataFilesSlice.reducer
