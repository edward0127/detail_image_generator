Rails.application.routes.draw do
  resources :image_projects, except: %i[edit] do
    member do
      post :upload_images
      post :upload_fonts
      post :import_excel
      post :preview
      post :generate_current
      post :generate
      get :download_zip

      post :add_task
      post :duplicate_task
      post :delete_task
      post :move_task

      post :add_layer
      post :duplicate_layer
      post :delete_layer
      post :move_layer

      patch "image_assets/:asset_id", to: "image_projects#update_image_asset", as: :update_image_asset
      delete "image_assets/:asset_id", to: "image_projects#destroy_image_asset", as: :image_asset
      patch "font_assets/:asset_id", to: "image_projects#update_font_asset", as: :update_font_asset
      delete "font_assets/:asset_id", to: "image_projects#destroy_font_asset", as: :font_asset
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  root "image_projects#index"
end
